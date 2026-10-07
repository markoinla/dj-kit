// analysis-eval: MusicalAnalyzer against a ground truth, read-only (never writes tags).
//
//   analysis-eval <rekordbox.xml | folder> [--models DIR] [--limit N] [--csv out.csv]
//
// XML: a Rekordbox collection export (File ▸ Export Collection in xml format); each
// DJ_PLAYLISTS/COLLECTION/TRACK's Location, AverageBpm, Tonality and Genre. Folder: every audio
// file under it, ground truth from its own BPM / key / genre tags. Detected BPM is folded with
// BPMRange.forGenre(genre). Build with xcodebuild (MLX's Metal shaders), e.g.
//
//   xcodebuild -scheme analysis-eval -configuration Release -destination 'platform=macOS' \
//     -derivedDataPath /tmp/dd build
//   /tmp/dd/Build/Products/Release/analysis-eval ~/Desktop/rekordbox.xml --limit 50
import AnalysisKit
import AudioExport
import Foundation

struct Options {
  var input: URL
  var models: URL
  var limit: Int?
  var csv: URL?

  static func parse(_ args: [String]) -> Options? {
    var input: URL?
    var models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJKit/models/beat-this", isDirectory: true)
    var limit: Int?
    var csv: URL?
    var i = 0
    while i < args.count {
      let a = args[i]
      func next() -> String? {
        i += 1
        return i < args.count ? args[i] : nil
      }
      switch a {
      case "--models": guard let v = next() else { return nil }; models = URL(fileURLWithPath: v, isDirectory: true)
      case "--limit": guard let v = next(), let n = Int(v), n > 0 else { return nil }; limit = n
      case "--csv": guard let v = next() else { return nil }; csv = URL(fileURLWithPath: v)
      case "-h", "--help": return nil
      default:
        if a.hasPrefix("-") || input != nil { return nil }
        input = URL(fileURLWithPath: a)
      }
      i += 1
    }
    guard let input else { return nil }
    return Options(input: input, models: models, limit: limit, csv: csv)
  }
}

/// One file and what it's supposed to be.
struct Truth {
  var url: URL
  var bpm: Double?
  var key: MusicalKey?
  /// The tag as written, when it didn't parse.
  var keyText: String?
  var genre: String?
}

// MARK: - Ground truth

/// Rekordbox's collection XML: TRACK elements directly under COLLECTION.
final class RekordboxXML: NSObject, XMLParserDelegate {
  private(set) var tracks: [Truth] = []
  private var inCollection = false

  static func read(_ url: URL) throws -> [Truth] {
    guard let parser = XMLParser(contentsOf: url) else { throw EvalError("Can't open \(url.path)") }
    let reader = RekordboxXML()
    parser.delegate = reader
    guard parser.parse() else {
      throw EvalError("Can't parse \(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "?")")
    }
    return reader.tracks
  }

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
              attributes: [String: String] = [:]) {
    if name == "COLLECTION" { inCollection = true; return }
    guard inCollection, name == "TRACK", let location = attributes["Location"],
      let url = Self.fileURL(location)
    else { return }
    let bpm = attributes["AverageBpm"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    let tonality = attributes["Tonality"]?.trimmingCharacters(in: .whitespaces)
    tracks.append(Truth(
      url: url, bpm: bpm, key: tonality.flatMap(MusicalKey.init(parsing:)),
      keyText: tonality?.isEmpty == false ? tonality : nil,
      genre: attributes["Genre"].flatMap { $0.isEmpty ? nil : $0 }))
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    if name == "COLLECTION" { inCollection = false }
  }

  /// "file://localhost/Users/me/Music/A%20B.mp3" -> /Users/me/Music/A B.mp3.
  static func fileURL(_ location: String) -> URL? {
    guard let url = URL(string: location), url.isFileURL || url.scheme == "file" else { return nil }
    let path = url.path(percentEncoded: false)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
  }
}

let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif"]

func folderTruth(_ folder: URL) async -> [Truth] {
  var files: [URL] = []
  let walker = FileManager.default.enumerator(
    at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
  while let url = walker?.nextObject() as? URL {
    if audioExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
  }
  files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  var out: [Truth] = []
  for url in files {
    let tags = await AudioTags.read(from: url)
    let keyText = tags.key?.trimmingCharacters(in: .whitespaces)
    out.append(Truth(
      url: url,
      bpm: tags.bpm.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil },
      key: keyText.flatMap(MusicalKey.init(parsing:)), keyText: keyText?.isEmpty == false ? keyText : nil,
      genre: tags.genre))
  }
  return out
}

// MARK: - Comparison

enum BPMVerdict: String {
  case agree, half, double, other, noTruth = "no truth", noDetection = "none"
}

enum KeyVerdict: String {
  case exact, relative, fifth, parallel, other, noTruth = "no truth", noDetection = "none"
}

func compareBPM(_ detected: Double?, _ truth: Double?) -> BPMVerdict {
  guard let truth else { return .noTruth }
  guard let detected else { return .noDetection }
  if abs(detected - truth) <= 0.5 { return .agree }
  if abs(detected * 2 - truth) <= 1 { return .half }
  if abs(detected - truth * 2) <= 1 { return .double }
  return .other
}

func compareKey(_ detected: MusicalKey?, _ truth: MusicalKey?) -> KeyVerdict {
  guard let truth else { return .noTruth }
  guard let detected else { return .noDetection }
  if detected == truth { return .exact }
  if detected.camelotNumber == truth.camelotNumber { return .relative }
  let step = (detected.camelotNumber - truth.camelotNumber + 12) % 12
  if detected.isMinor == truth.isMinor, step == 1 || step == 11 { return .fifth }
  if detected.tonic == truth.tonic { return .parallel }
  return .other
}

struct Row {
  var truth: Truth
  var bpm: Double?
  var steady: Bool?
  var key: MusicalKey?
  var margin: Double?
  var seconds: Double
  var error: String?
  var bpmVerdict: BPMVerdict
  var keyVerdict: KeyVerdict
}

struct EvalError: LocalizedError, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
  var errorDescription: String? { description }
}

func percent(_ n: Int, of total: Int) -> String {
  total > 0 ? String(format: "%5.1f%%", 100 * Double(n) / Double(total)) : "    –"
}

func keyLabel(_ key: MusicalKey?) -> String {
  key.map { "\($0.camelot) \($0.musical)" } ?? "–"
}

func csvField(_ s: String) -> String {
  s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
}

// MARK: - Main

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
  FileHandle.standardError.write(Data(
    "usage: analysis-eval <rekordbox.xml | folder> [--models DIR] [--limit N] [--csv out.csv]\n".utf8))
  exit(64)
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: options.input.path, isDirectory: &isDirectory) else {
  FileHandle.standardError.write(Data("analysis-eval: no such file or folder: \(options.input.path)\n".utf8))
  exit(66)
}

var truths: [Truth]
do {
  truths = isDirectory.boolValue ? await folderTruth(options.input) : try RekordboxXML.read(options.input)
} catch {
  FileHandle.standardError.write(Data("analysis-eval: \(error)\n".utf8))
  exit(65)
}
if let limit = options.limit { truths = Array(truths.prefix(limit)) }
print("\(truths.count) tracks from \(options.input.lastPathComponent); models in \(options.models.path)")

let analyzer = MusicalAnalyzer(modelsDirectory: options.models)
var rows: [Row] = []
for (index, truth) in truths.enumerated() {
  let start = Date()
  var row = Row(truth: truth, seconds: 0, bpmVerdict: .noTruth, keyVerdict: .noTruth)
  do {
    guard FileManager.default.fileExists(atPath: truth.url.path) else { throw EvalError("missing file") }
    let analysis = try await analyzer.analyze(truth.url, status: { line in
      if !line.hasPrefix("Analyzing") { print("  \(line)") }
    })
    row.bpm = analysis.tempo?.bpm(in: BPMRange.forGenre(truth.genre))
    row.steady = analysis.tempo?.isSteady
    row.key = analysis.key?.key
    row.margin = analysis.key?.margin
  } catch {
    row.error = "\(error.localizedDescription)"
  }
  row.seconds = Date().timeIntervalSince(start)
  row.bpmVerdict = row.error == nil ? compareBPM(row.bpm, truth.bpm) : (truth.bpm == nil ? .noTruth : .noDetection)
  row.keyVerdict = row.error == nil ? compareKey(row.key, truth.key) : (truth.key == nil ? .noTruth : .noDetection)
  rows.append(row)
  let bpmText = row.bpm.map { (row.steady == false ? "~" : "") + BPMFormat.string($0) } ?? "–"
  print(String(format: "[%d/%d] %5.2fs  ", index + 1, truths.count, row.seconds)
    + "\(bpmText) BPM (\(truth.bpm.map(BPMFormat.string) ?? "–"))  \(keyLabel(row.key)) (\(truth.keyText ?? "–"))  "
    + truth.url.lastPathComponent + (row.error.map { "  ERROR: \($0)" } ?? ""))
}

// Summary.
let analyzed = rows.filter { $0.error == nil }
let bpmRows = rows.filter { $0.bpmVerdict != .noTruth }
let keyRows = rows.filter { $0.keyVerdict != .noTruth }
func count(_ verdict: BPMVerdict) -> Int { bpmRows.filter { $0.bpmVerdict == verdict }.count }
func count(_ verdict: KeyVerdict) -> Int { keyRows.filter { $0.keyVerdict == verdict }.count }

print("\n== Summary ==")
print("tracks \(rows.count), analyzed \(analyzed.count), errors \(rows.count - analyzed.count)")
if !analyzed.isEmpty {
  let mean = analyzed.map(\.seconds).reduce(0, +) / Double(analyzed.count)
  print(String(format: "mean time per track %.2f s", mean))
}
print("unsteady tempo \(analyzed.filter { $0.steady == false }.count), no tempo \(analyzed.filter { $0.bpm == nil }.count), no key \(analyzed.filter { $0.key == nil }.count)")
if bpmRows.isEmpty {
  print("BPM: no ground truth")
} else {
  print("BPM (\(bpmRows.count) with ground truth, ±0.5):")
  for v in [BPMVerdict.agree, .half, .double, .other, .noDetection] {
    print("  \(v.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(format: "%4d", count(v)))  \(percent(count(v), of: bpmRows.count))")
  }
}
if keyRows.isEmpty {
  print("Key: no ground truth")
} else {
  let unparsed = rows.filter { $0.truth.key == nil && $0.truth.keyText != nil }.count
  print("Key (\(keyRows.count) with ground truth\(unparsed > 0 ? ", \(unparsed) unreadable tags skipped" : "")):")
  for v in [KeyVerdict.exact, .relative, .fifth, .parallel, .other, .noDetection] {
    print("  \(v.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(format: "%4d", count(v)))  \(percent(count(v), of: keyRows.count))")
  }
}

let mismatches = rows.filter {
  $0.error != nil || ![.agree, .noTruth].contains($0.bpmVerdict) || ![.exact, .noTruth].contains($0.keyVerdict)
}
if !mismatches.isEmpty {
  print("\n== Mismatches ==")
  for row in mismatches {
    var parts: [String] = []
    if let error = row.error {
      print("  \(row.truth.url.lastPathComponent): error: \(error)")
      continue
    }
    if ![.agree, .noTruth].contains(row.bpmVerdict) {
      parts.append("BPM \(row.bpm.map(BPMFormat.string) ?? "–") vs \(row.truth.bpm.map(BPMFormat.string) ?? "–") (\(row.bpmVerdict.rawValue))")
    }
    if ![.exact, .noTruth].contains(row.keyVerdict) {
      parts.append("key \(keyLabel(row.key)) vs \(keyLabel(row.truth.key)) (\(row.keyVerdict.rawValue))")
    }
    print("  \(row.truth.url.lastPathComponent): " + parts.joined(separator: "; "))
  }
}

if let csv = options.csv {
  var lines = ["file,genre,truth_bpm,bpm,steady,bpm_result,truth_key,key,key_margin,key_result,seconds,error"]
  for r in rows {
    lines.append([
      r.truth.url.path, r.truth.genre ?? "", r.truth.bpm.map { String($0) } ?? "", r.bpm.map { String(format: "%.3f", $0) } ?? "",
      r.steady.map { $0 ? "1" : "0" } ?? "", r.bpmVerdict.rawValue,
      r.truth.key?.camelot ?? r.truth.keyText ?? "", r.key?.camelot ?? "", r.margin.map { String(format: "%.3f", $0) } ?? "",
      r.keyVerdict.rawValue, String(format: "%.3f", r.seconds), r.error ?? "",
    ].map(csvField).joined(separator: ","))
  }
  do {
    try (lines.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
    print("\nwrote \(csv.path)")
  } catch {
    FileHandle.standardError.write(Data("analysis-eval: can't write \(csv.path): \(error.localizedDescription)\n".utf8))
  }
}

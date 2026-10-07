// Tests that need the Beat This! weights. Run with xcodebuild (MLX needs its Metal shaders):
//
//   cd Packages/AnalysisKit && xcodebuild test -scheme AnalysisKit-Package -destination 'platform=macOS' \
//     -only-testing:AnalysisKitTests/TempoModelTests
//
// Weights come from TEST_RUNNER_BEAT_THIS_MODELS (a directory) or the app's
// ~/Library/Application Support/DJKit/models/beat-this; without them these tests are skipped,
// unless TEST_RUNNER_BEAT_THIS_DOWNLOAD=1 lets prepare() fetch them (81 MB) into that directory.
// Optional, with TEST_RUNNER_ prefixes (xcodebuild strips it):
//   BEAT_THIS_REF_DIR  output of a reference run of the Python beat_this (per-track folders with
//                      mono22k.f32, mel.f32, logits_final0.f32, beats_final0.txt) -> parity tests
//   BEAT_THIS_AUDIO    folder of audio files matching those track folders -> end-to-end + speed
import AVFoundation
import Foundation
import Testing
@testable import AnalysisKit

enum TempoTestEnv {
  static let env = ProcessInfo.processInfo.environment
  static var modelsDirectory: URL {
    if let dir = env["BEAT_THIS_MODELS"] { return URL(fileURLWithPath: dir, isDirectory: true) }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJKit/models/beat-this", isDirectory: true)
  }
  static var hasWeights: Bool {
    env["BEAT_THIS_DOWNLOAD"] == "1"
      || FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(BeatTracker.weightsFileName).path)
  }
  static var refDir: URL? { env["BEAT_THIS_REF_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
  static var audioDir: URL? { env["BEAT_THIS_AUDIO"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

  static func tracker() async throws -> BeatTracker {
    let t = BeatTracker(modelsDirectory: modelsDirectory)
    try await t.prepare { _ in }
    return t
  }

  static func readFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  static func readBeats(_ url: URL) throws -> [Double] {
    try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Double($0) }
  }

  /// Decodes any AVAudioFile-readable file to mono at its own rate.
  static func decodeMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let n = Int(buffer.frameLength), ch = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<ch {
      let p = buffer.floatChannelData![c]
      for i in 0..<n { mono[i] += p[i] }
    }
    if ch > 1 { for i in 0..<n { mono[i] /= Float(ch) } }
    return (mono, format.sampleRate)
  }

  /// mir_eval-style beat F-measure (±70 ms, one-to-one greedy matching) and the largest
  /// deviation among matched beats.
  static func fMeasure(reference: [Double], estimate: [Double]) -> (f: Double, maxDeviation: Double) {
    var used = [Bool](repeating: false, count: estimate.count)
    var hits = 0
    var worst = 0.0
    var j = 0
    for r in reference {
      while j < estimate.count && estimate[j] < r - 0.07 { j += 1 }
      var best = -1
      var k = j
      while k < estimate.count && estimate[k] <= r + 0.07 {
        if !used[k] && (best < 0 || abs(estimate[k] - r) < abs(estimate[best] - r)) { best = k }
        k += 1
      }
      if best >= 0 {
        used[best] = true
        hits += 1
        worst = max(worst, abs(estimate[best] - r))
      }
    }
    guard !reference.isEmpty, !estimate.isEmpty else { return (0, 0) }
    let p = Double(hits) / Double(estimate.count), r = Double(hits) / Double(reference.count)
    return (p + r > 0 ? 2 * p * r / (p + r) : 0, worst)
  }

  /// Kick on every beat, clap on 2 and 4, closed hat on the off-beats; 44.1 kHz.
  static func drumLoop(bpm: Double, seconds: Double, rate: Double = 44_100) -> [Float] {
    var out = [Float](repeating: 0, count: Int(seconds * rate))
    var noise = SystemRandomNumberGenerator()
    let period = 60 / bpm
    var beat = 0
    while Double(beat) * period < seconds {
      let start = Int(Double(beat) * period * rate)
      for i in 0..<Int(0.25 * rate) where start + i < out.count {  // kick: pitch-swept sine
        let t = Double(i) / rate
        let phase = 2 * Double.pi * (50 * t + 90 * (1 - exp(-t * 30)) / 30)
        out[start + i] += Float(0.9 * sin(phase) * exp(-t * 12))
      }
      if beat % 2 == 1 {
        for i in 0..<Int(0.15 * rate) where start + i < out.count {  // clap: noise burst
          out[start + i] += Float(0.4 * Double.random(in: -1...1, using: &noise) * exp(-Double(i) / rate * 25))
        }
      }
      let hat = start + Int(period / 2 * rate)
      for i in 0..<Int(0.04 * rate) where hat + i < out.count {
        out[hat + i] += Float(0.15 * Double.random(in: -1...1, using: &noise) * exp(-Double(i) / rate * 120))
      }
      beat += 1
    }
    return out
  }
}

struct TempoWeightsTests {
  @Test func checksumMismatchDeletes() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("beat-this-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent(BeatTracker.weightsFileName)
    try Data("not a model".utf8).write(to: file)
    let tracker = BeatTracker(modelsDirectory: dir)
    #expect(await tracker.isPrepared)
    await #expect(throws: BeatTrackerError.self) { try await tracker.prepare { _ in } }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}

@Suite(.enabled(if: TempoTestEnv.hasWeights, "Beat This! weights not available"), .serialized)
struct TempoModelTests {
  @Test(arguments: [87.0, 124, 128, 140, 174])
  func syntheticDrumLoop(bpm: Double) async throws {
    let tracker = try await TempoTestEnv.tracker()
    let audio = TempoTestEnv.drumLoop(bpm: bpm, seconds: 60)
    let e = try #require(try await tracker.tempo(monoSamples: audio, sampleRate: 44_100))
    let expected = TempoEstimate(rawBPM: bpm, beatCount: 0, stability: 0).bpm(in: BPMRange.standard)
    let got = e.bpm(in: BPMRange.standard)
    print("drum loop \(bpm): raw \(e.rawBPM), folded \(got), beats \(e.beatCount), stability \(e.stability)")
    #expect(abs(got - expected) <= 0.5)
    #expect(e.isSteady)
  }

  @Test func silenceHasNoTempo() async throws {
    let tracker = try await TempoTestEnv.tracker()
    let e = try await tracker.tempo(monoSamples: [Float](repeating: 0, count: 44_100 * 20), sampleRate: 44_100)
    #expect(e == nil)
  }

  @Test func cancellation() async throws {
    let tracker = try await TempoTestEnv.tracker()
    let audio = TempoTestEnv.drumLoop(bpm: 128, seconds: 360)
    let task = Task { try await tracker.tempo(monoSamples: audio, sampleRate: 44_100) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  /// Mel frontend against torchaudio on the identical 22050 Hz signal.
  @Test(.enabled(if: TempoTestEnv.refDir != nil))
  func melParity() throws {
    let ref = try #require(TempoTestEnv.refDir)
    var worst: Float = 0
    for track in try Self.tracks(ref) {
      let signal = try TempoTestEnv.readFloats(track.appendingPathComponent("mono22k.f32"))
      let expected = try TempoTestEnv.readFloats(track.appendingPathComponent("mel.f32"))
      let (mel, frames) = MelSpectrogram.compute(signal)
      #expect(mel.count == expected.count)
      var maxAbs: Float = 0, maxVal: Float = 0
      for i in 0..<min(mel.count, expected.count) {
        maxAbs = max(maxAbs, abs(mel[i] - expected[i]))
        maxVal = max(maxVal, abs(expected[i]))
      }
      print("mel \(track.lastPathComponent): frames \(frames), max |Δ| \(maxAbs) (max value \(maxVal))")
      worst = max(worst, maxAbs)
    }
    #expect(worst < 1e-3)
  }

  /// Network + postprocessing against PyTorch, fed the reference log-mel.
  @Test(.enabled(if: TempoTestEnv.refDir != nil), arguments: ["fp32", "fp16"])
  func networkParity(precision: String) async throws {
    let ref = try #require(TempoTestEnv.refDir)
    let tracker = try await TempoTestEnv.tracker()
    await tracker.setPrecision(fp16: precision == "fp16")
    var minF = 1.0
    for track in try Self.tracks(ref) {
      let mel = try TempoTestEnv.readFloats(track.appendingPathComponent("mel.f32"))
      let expected = try TempoTestEnv.readFloats(track.appendingPathComponent("logits_final0.f32"))
      let refBeats = try TempoTestEnv.readBeats(track.appendingPathComponent("beats_final0.txt"))
      let logits = try await tracker.logits(mel: mel, frames: mel.count / MelSpectrogram.bands)
      var maxAbs: Float = 0
      for i in 0..<min(logits.count, expected.count) { maxAbs = max(maxAbs, abs(logits[i] - expected[i])) }
      let beats = BeatTracker.pickPeaks(logits).map { $0 / 50 }
      let (f, dev) = TempoTestEnv.fMeasure(reference: refBeats, estimate: beats)
      let bpm = TempoEstimate(beatTimes: beats)?.rawBPM ?? 0
      let refBPM = TempoEstimate(beatTimes: refBeats)?.rawBPM ?? 0
      print("\(precision) \(track.lastPathComponent): logits max |Δ| \(maxAbs), beats \(beats.count)/\(refBeats.count), F \(f), max dev \(dev) s, BPM \(bpm) vs \(refBPM)")
      minF = min(minF, f)
    }
    #expect(minF > (precision == "fp32" ? 0.995 : 0.98))
  }

  /// Swift decode + resample + everything, against the Python run on the same files.
  @Test(.enabled(if: TempoTestEnv.refDir != nil && TempoTestEnv.audioDir != nil))
  func endToEndAgainstPython() async throws {
    let ref = try #require(TempoTestEnv.refDir), audio = try #require(TempoTestEnv.audioDir)
    let tracker = try await TempoTestEnv.tracker()
    let files = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let name = file.deletingPathExtension().lastPathComponent
      let refBeatsURL = ref.appendingPathComponent(name).appendingPathComponent("beats_final0.txt")
      guard FileManager.default.fileExists(atPath: refBeatsURL.path) else { continue }
      let refBeats = try TempoTestEnv.readBeats(refBeatsURL)
      let (samples, rate) = try TempoTestEnv.decodeMono(file)
      let clock = ContinuousClock()
      let t0 = clock.now
      let beats = try await tracker.beats(monoSamples: samples, sampleRate: rate)
      let elapsed = clock.now - t0
      let (f, dev) = TempoTestEnv.fMeasure(reference: refBeats, estimate: beats)
      let e = TempoEstimate(beatTimes: beats), r = TempoEstimate(beatTimes: refBeats)
      print(String(format: "e2e %@: F %.4f, max dev %.3f s, BPM %.3f vs %.3f (median-IBI %.2f), stability %.4f, %@",
                   name, f, dev, e?.rawBPM ?? 0, r?.rawBPM ?? 0, 60 / TempoEstimate.median(zip(refBeats.dropFirst(), refBeats).map { $0 - $1 }),
                   e?.stability ?? -1, "\(elapsed)"))
      #expect(f > 0.97, "\(name)")
      #expect(abs((e?.rawBPM ?? 0) - (r?.rawBPM ?? 0)) < 0.1, "\(name)")
    }
  }

  /// 6 minutes of a real track (looped), timed after a warm-up. Numbers mean something only in
  /// Release: add `-configuration Release ENABLE_TESTABILITY=YES`.
  @Test(.enabled(if: TempoTestEnv.audioDir != nil))
  func speed() async throws {
    let audio = try #require(TempoTestEnv.audioDir)
    let file = try #require(try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
      .filter { ["flac", "wav", "mp3", "aiff"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }.first)
    let (samples, rate) = try TempoTestEnv.decodeMono(file)
    var long: [Float] = []
    while long.count < Int(360 * rate) { long += samples }
    long = Array(long.prefix(Int(360 * rate)))
    let tracker = try await TempoTestEnv.tracker()
    for precision in ["fp16", "fp32"] {
      await tracker.setPrecision(fp16: precision == "fp16")
      _ = try await tracker.tempo(monoSamples: Array(long.prefix(Int(30 * rate))), sampleRate: rate)  // load + warm-up
      _ = await tracker.takePeakMemory()
      let clock = ContinuousClock()
      var times: [Duration] = []
      var result: TempoEstimate?
      for _ in 0..<3 {
        let t0 = clock.now
        result = try await tracker.tempo(monoSamples: long, sampleRate: rate)
        times.append(clock.now - t0)
      }
      let t0 = clock.now
      let signal = try MelSpectrogram.resample(long, from: rate)
      let t1 = clock.now
      _ = MelSpectrogram.compute(signal)
      let t2 = clock.now
      let peak = await tracker.takePeakMemory()
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      print("speed \(precision) 360 s: tempo() \(times), resample \(t1 - t0), mel \(t2 - t1), BPM \(result?.rawBPM ?? 0), MLX peak \(peak >> 20) MB, process max RSS \(usage.ru_maxrss >> 20) MB")
    }
  }

  static func tracks(_ ref: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: ref, includingPropertiesForKeys: nil)
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mel.f32").path) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

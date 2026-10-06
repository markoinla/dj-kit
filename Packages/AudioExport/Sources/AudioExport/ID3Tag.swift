import Foundation

// MARK: - ID3v2 (MP3, and the AIFF / WAV "ID3 " chunk)

enum ID3v2 {
  /// A complete, fresh ID3v2.3 tag with these tags.
  static func tag(_ tags: AudioTags) -> Data {
    var tag = ID3Tag()
    tag.merge(tags)
    return tag.serialized()
  }
}

/// An ID3v2.3 or v2.4 tag as a list of raw frames, so frames we don't know (BPM,
/// key, Rekordbox and Serato GEOBs) survive a rewrite byte for byte.
///
/// Parsing undoes tag-level unsynchronisation and skips the extended header, and a
/// v2.2 tag becomes v2.3 (known frames converted, the rest dropped); `serialized()`
/// writes neither, so those come back as a plain tag.
struct ID3Tag {
  struct Frame {
    var id: String
    /// The two flag bytes, as stored (v2.3 and v2.4 differ; kept verbatim).
    var flags: [UInt8] = [0, 0]
    var body: Data
  }

  /// 3 or 4.
  var major: UInt8 = 3
  var frames: [Frame] = []

  /// The whole tag's size on disk (header, body, v2.4 footer) from its first 10
  /// bytes, or nil when they aren't an ID3v2 header.
  static func totalSize(header: Data) -> Int? {
    let h = [UInt8](header.prefix(10))
    guard h.count == 10, h[0] == 0x49, h[1] == 0x44, h[2] == 0x33, h[3] != 0xFF, h[4] != 0xFF,
      h[6...9].allSatisfy({ $0 < 0x80 })
    else { return nil }
    let footer = h[3] == 4 && h[5] & 0x10 != 0 ? 10 : 0
    return 10 + unsyncsafe(h[6...9]) + footer
  }

  /// Parses a whole tag, header first. Nil when it isn't one we understand.
  static func parse(_ data: Data) -> ID3Tag? {
    let d = [UInt8](data)
    guard totalSize(header: data) != nil, (2...4).contains(d[3]) else { return nil }
    let major = d[3], tagFlags = d[5]
    var body = Array(d[10..<min(d.count, 10 + unsyncsafe(d[6...9]))])
    if tagFlags & 0x80 != 0, major < 4 { body = deunsync(body) }
    var pos = 0
    if tagFlags & 0x40 != 0 {
      if major == 2 { return ID3Tag() }  // v2.2: the flag means compression; nothing readable
      guard body.count >= 4 else { return ID3Tag() }
      pos = major == 3 ? Int(be32(body[0..<4])) + 4 : unsyncsafe(body[0..<4])
    }
    var tag = ID3Tag(major: major == 2 ? 3 : major)
    let header = major == 2 ? 6 : 10
    while pos + header <= body.count {
      let idBytes = body[pos..<pos + (major == 2 ? 3 : 4)]
      guard idBytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { break }
      let id = String(decoding: idBytes, as: UTF8.self)
      let size: Int
      var flags: [UInt8] = [0, 0]
      if major == 2 {
        size = Int(body[pos + 3]) << 16 | Int(body[pos + 4]) << 8 | Int(body[pos + 5])
      } else {
        let raw = body[pos + 4..<pos + 8]
        // iTunes once wrote v2.4 frame sizes as plain integers; a byte ≥ 0x80 gives that away.
        size = major == 4 && raw.allSatisfy({ $0 < 0x80 }) ? unsyncsafe(raw) : Int(be32(raw))
        flags = [body[pos + 8], body[pos + 9]]
      }
      let start = pos + header
      guard size >= 0, start + size <= body.count else { break }
      let frameBody = Data(body[start..<start + size])
      if major == 2 {
        if let frame = convertV22(id: id, body: frameBody) { tag.frames.append(frame) }
      } else {
        tag.frames.append(Frame(id: id, flags: flags, body: frameBody))
      }
      pos = start + size
    }
    return tag
  }

  /// The tag in its major version: no unsynchronisation, extended header, footer or padding.
  func serialized() -> Data {
    var out = Data()
    for frame in frames {
      out.append(contentsOf: Array(frame.id.utf8.prefix(4)))
      out.append(major == 4 ? Self.syncsafe(frame.body.count) : bigEndian32(UInt32(frame.body.count)))
      out.append(contentsOf: frame.flags.count == 2 ? frame.flags : [0, 0])
      out.append(frame.body)
    }
    var tag = Data("ID3".utf8)
    tag.append(contentsOf: [major, 0x00, 0x00])
    tag.append(Self.syncsafe(out.count))
    tag.append(out)
    return tag
  }

  // MARK: Merge

  /// Every non-nil field replaces its frame(s), in place; everything else stays.
  mutating func merge(_ tags: AudioTags) {
    if let title = tags.title { replace(["TIT2"], with: [.text("TIT2", title)]) }
    if let artist = tags.artist { replace(["TPE1"], with: [.text("TPE1", artist)]) }
    if let album = tags.album { replace(["TALB"], with: [.text("TALB", album)]) }
    if let genre = tags.genre { replace(["TCON"], with: [.text("TCON", genre)]) }
    if let year = tags.year {
      let trimmed = year.trimmingCharacters(in: .whitespaces)
      if major == 4 {
        replace(["TDRC", "TYER", "TDAT", "TIME"], with: [.text("TDRC", trimmed)])
      } else {
        let digits = String(trimmed.prefix(4))
        let valid = digits.count == 4 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
        replace(["TYER", "TDAT", "TIME", "TRDA", "TDRC"], with: valid ? [.text("TYER", digits)] : [])
      }
    }
    if let label = tags.label { replace(["TPUB"], with: [.text("TPUB", label)]) }
    if let isrc = tags.isrc { replace(["TSRC"], with: [.text("TSRC", isrc)]) }
    let major = major
    if let comment = tags.comment {
      replace(where: {
        $0.id == "COMM" && Self.content(of: $0, major: major).flatMap(Self.comment)?.description.isEmpty ?? false
      }, with: [.comment(comment)])
    }
    if let artwork = tags.artwork {
      replace(where: {
        $0.id == "APIC" && Self.content(of: $0, major: major).flatMap { Self.picture(Data($0)) }?.type == 3
      }, with: [.picture(artwork, mime: tags.artworkMIMEType)])
    }
  }

  private mutating func replace(_ ids: Set<String>, with new: [Frame]) {
    replace(where: { ids.contains($0.id) }, with: new)
  }

  /// Removes the matching frames and puts `new` where the first of them was (or at the end).
  private mutating func replace(where match: (Frame) -> Bool, with new: [Frame]) {
    let at = frames.firstIndex(where: match) ?? frames.count
    frames.removeAll(where: match)
    frames.insert(contentsOf: new, at: min(at, frames.count))
  }

  // MARK: Read

  /// The fields AudioTags knows about. Empty strings count as missing.
  var audioTags: AudioTags {
    var tags = AudioTags()
    func text(_ ids: String...) -> String? {
      for id in ids {
        for frame in frames where frame.id == id {
          guard let body = Self.content(of: frame, major: major), let first = body.first else { continue }
          let values = Self.strings(Data(body.dropFirst()), encoding: first)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
          if !values.isEmpty { return values.joined(separator: "; ") }
        }
      }
      return nil
    }
    tags.title = text("TIT2")
    tags.artist = text("TPE1")
    tags.album = text("TALB")
    tags.genre = text("TCON").flatMap(Self.genreName)
    tags.year = text("TDRC", "TYER", "TDOR", "TORY")
    tags.label = text("TPUB")
    tags.isrc = text("TSRC")
    tags.comment = frames.lazy.filter { $0.id == "COMM" }
      .compactMap { Self.content(of: $0, major: major).flatMap(Self.comment) }
      .first { $0.description.isEmpty && !$0.text.isEmpty }?.text
    let pictures = frames.filter { $0.id == "APIC" }.compactMap { Self.content(of: $0, major: major).flatMap { Self.picture(Data($0)) } }
    if let art = (pictures.first { $0.type == 3 } ?? pictures.first)?.data, !art.isEmpty { tags.artwork = art }
    return tags
  }

  /// The frame's data with the format bytes (grouping, data length, frame
  /// unsynchronisation) undone; nil for compressed or encrypted frames.
  static func content(of frame: Frame, major: UInt8) -> [UInt8]? {
    var bytes = [UInt8](frame.body)
    let f = frame.flags.count == 2 ? frame.flags[1] : 0
    if major == 4 {
      if f & 0x0C != 0 { return nil }
      var skip = 0
      if f & 0x40 != 0 { skip += 1 }
      if f & 0x01 != 0 { skip += 4 }
      bytes = Array(bytes.dropFirst(skip))
      if f & 0x02 != 0 { bytes = Self.deunsync(bytes) }
    } else {
      if f & 0xC0 != 0 { return nil }
      if f & 0x20 != 0 { bytes = Array(bytes.dropFirst()) }
    }
    return bytes
  }

  // MARK: Frame bodies

  /// "(17)", "17", "(17)Rock", "RX" → a genre name.
  static func genreName(_ raw: String) -> String? {
    var s = raw
    var refs: [String] = []
    while s.hasPrefix("("), !s.hasPrefix("(("), let close = s.firstIndex(of: ")") {
      refs.append(String(s[s.index(after: s.startIndex)..<close]))
      s = String(s[s.index(after: close)...])
    }
    if s.hasPrefix("((") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespaces)
    if !s.isEmpty, let n = Int(s), n >= 0, n < id3v1Genres.count { return id3v1Genres[n] }
    if !s.isEmpty { return s }
    for ref in refs {
      if let n = Int(ref), n >= 0, n < id3v1Genres.count { return id3v1Genres[n] }
      if ref == "RX" { return "Remix" }
      if ref == "CR" { return "Cover" }
    }
    return nil
  }

  /// COMM: (language, description, text).
  static func comment(_ b: [UInt8]) -> (description: String, text: String)? {
    guard b.count >= 4 else { return nil }
    let (desc, rest) = splitTerminated(Array(b[4...]), encoding: b[0])
    return (decode(desc, encoding: b[0]).trimmingCharacters(in: .whitespacesAndNewlines),
            decode(rest, encoding: b[0]).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// APIC: (picture type, image bytes).
  static func picture(_ body: Data) -> (type: UInt8, data: Data)? {
    let b = [UInt8](body)
    guard b.count >= 4, let mimeEnd = b[1...].firstIndex(of: 0), mimeEnd + 1 < b.count else { return nil }
    let type = b[mimeEnd + 1]
    let (_, data) = splitTerminated(Array(b[(mimeEnd + 2)...]), encoding: b[0])
    return (type, Data(data))
  }

  /// A text frame body split at its terminators; v2.4 separates values with them.
  static func strings(_ data: Data, encoding: UInt8) -> [String] {
    var rest = [UInt8](data)
    var out: [String] = []
    while !rest.isEmpty {
      let (first, tail) = splitTerminated(rest, encoding: encoding)
      out.append(decode(first, encoding: encoding))
      rest = tail
    }
    return out
  }

  /// Bytes up to the encoding's terminator, and what follows it.
  static func splitTerminated(_ b: [UInt8], encoding: UInt8) -> ([UInt8], [UInt8]) {
    if encoding == 1 || encoding == 2 {
      var i = 0
      while i + 1 < b.count {
        if b[i] == 0, b[i + 1] == 0 { return (Array(b[..<i]), Array(b[(i + 2)...])) }
        i += 2
      }
      return (b, [])
    }
    guard let i = b.firstIndex(of: 0) else { return (b, []) }
    return (Array(b[..<i]), Array(b[(i + 1)...]))
  }

  static func decode(_ b: [UInt8], encoding: UInt8) -> String {
    switch encoding {
    case 1, 2:
      var bytes = b
      var bigEndian = encoding == 2
      if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { bigEndian = false; bytes.removeFirst(2) }
      else if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { bigEndian = true; bytes.removeFirst(2) }
      var units: [UInt16] = []
      var i = 0
      while i + 1 < bytes.count {
        let hi = UInt16(bytes[bigEndian ? i : i + 1]), lo = UInt16(bytes[bigEndian ? i + 1 : i])
        units.append(hi << 8 | lo)
        i += 2
      }
      return String(decoding: units, as: UTF16.self)
    case 3:
      return String(decoding: b, as: UTF8.self)
    default:
      return String(b.map { Character(Unicode.Scalar($0)) })
    }
  }

  // MARK: v2.2

  private static let v22Names: [String: String] = [
    "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3",
    "TP4": "TPE4", "TAL": "TALB", "TCO": "TCON", "TYE": "TYER", "TPB": "TPUB", "TRC": "TSRC",
    "TBP": "TBPM", "TKE": "TKEY", "TRK": "TRCK", "TPA": "TPOS", "TCM": "TCOM", "TXT": "TEXT",
    "TLA": "TLAN", "TLE": "TLEN", "TCR": "TCOP", "TEN": "TENC", "TSS": "TSSE", "TOA": "TOPE",
    "TOT": "TOAL", "TOR": "TORY", "TDA": "TDAT", "TIM": "TIME", "TXX": "TXXX", "COM": "COMM",
    "ULT": "USLT", "WXX": "WXXX", "UFI": "UFID", "GEO": "GEOB", "POP": "POPM", "CNT": "PCNT",
  ]

  /// A v2.2 frame as v2.3 (same body layout, except PIC → APIC); nil when unknown.
  private static func convertV22(id: String, body: Data) -> Frame? {
    if id == "PIC" {
      let b = [UInt8](body)
      guard b.count >= 5 else { return nil }
      let format = String(decoding: b[1..<4], as: UTF8.self).uppercased()
      var out = Data([b[0]])
      out.append(contentsOf: Array((format == "PNG" ? "image/png" : "image/jpeg").utf8)); out.append(0)
      out.append(contentsOf: b[4...])
      return Frame(id: "APIC", body: out)
    }
    guard let name = v22Names[id] else { return nil }
    return Frame(id: name, body: body)
  }

  // MARK: Bytes

  static func deunsync(_ b: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(b.count)
    var i = 0
    while i < b.count {
      out.append(b[i])
      if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 { i += 1 }
      i += 1
    }
    return out
  }

  static func unsyncsafe<C: Collection<UInt8>>(_ b: C) -> Int {
    b.prefix(4).reduce(0) { $0 << 7 | Int($1 & 0x7F) }
  }

  static func syncsafe(_ value: Int) -> Data {
    let v = UInt32(clamping: value)
    return Data([UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)])
  }

  private static func be32<C: Collection<UInt8>>(_ b: C) -> UInt32 {
    b.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
  }
}

extension ID3Tag.Frame {
  /// A text frame: ISO-8859-1 when plain ASCII, else UTF-16 with BOM (valid in v2.3 and v2.4).
  static func text(_ id: String, _ text: String) -> Self {
    let ascii = isASCII(text)
    var body = Data([ascii ? 0x00 : 0x01])
    appendText(text, ascii: ascii, to: &body)
    return Self(id: id, body: body)
  }

  /// COMM, language "eng", empty description.
  static func comment(_ text: String) -> Self {
    let ascii = isASCII(text)
    var body = Data([ascii ? 0x00 : 0x01])
    body.append(contentsOf: Array("eng".utf8))
    body.append(contentsOf: ascii ? [0x00] : [0xFF, 0xFE, 0x00, 0x00])  // empty description
    appendText(text, ascii: ascii, to: &body)
    return Self(id: "COMM", body: body)
  }

  /// APIC, front cover, empty description.
  static func picture(_ data: Data, mime: String) -> Self {
    var body = Data([0x00])
    body.append(contentsOf: Array(mime.utf8)); body.append(0)
    body.append(0x03)  // front cover
    body.append(0)  // empty description
    body.append(data)
    return Self(id: "APIC", body: body)
  }

  private static func isASCII(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { $0.value < 0x80 } }

  private static func appendText(_ text: String, ascii: Bool, to body: inout Data) {
    if ascii {
      body.append(contentsOf: Array(text.utf8))
    } else {
      body.append(contentsOf: [0xFF, 0xFE])
      for unit in text.utf16 { body.append(UInt8(unit & 0xFF)); body.append(UInt8(unit >> 8)) }
    }
  }
}

/// ID3v1 genres 0–147 (the original 80 plus Winamp's), for "(17)"-style references
/// and the M4A "gnre" atom.
let id3v1Genres: [String] = [
  "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
  "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
  "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal",
  "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip",
  "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
  "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
  "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap",
  "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes",
  "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll",
  "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival",
  "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock",
  "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech",
  "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove",
  "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul",
  "Freestyle", "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall", "Goa",
  "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk", "Beat",
  "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian",
  "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
]

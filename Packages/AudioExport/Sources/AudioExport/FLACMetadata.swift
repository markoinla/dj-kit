import Foundation

// MARK: - FLAC metadata blocks

enum FLACTags {
  static let vendor = "DJ Tools (Core Audio FLAC)"

  struct Block {
    var type: UInt8
    var body: Data
  }

  /// Vorbis comment keys per AudioTags field: the one we write, then the ones it replaces.
  private static var keys: [(write: String, replace: Set<String>, path: KeyPath<AudioTags, String?>)] {
    [
      ("TITLE", ["TITLE"], \.title),
      ("ARTIST", ["ARTIST"], \.artist),
      ("ALBUM", ["ALBUM"], \.album),
      ("GENRE", ["GENRE"], \.genre),
      ("DATE", ["DATE", "YEAR"], \.year),
      ("LABEL", ["LABEL", "ORGANIZATION"], \.label),
      ("ISRC", ["ISRC"], \.isrc),
      ("COMMENT", ["COMMENT"], \.comment),
      ("BPM", ["BPM", "TEMPO"], \.bpmText),
      ("INITIALKEY", ["INITIALKEY", "KEY"], \.keyText),
    ]
  }

  /// The metadata blocks after the "fLaC" marker at `start` (an offset into
  /// `flac`), and the offset of the first audio frame. Nil when it isn't FLAC
  /// or the metadata is cut short.
  static func blocks(in flac: Data, at start: Int = 0) -> (blocks: [Block], audioStart: Int)? {
    let base = flac.startIndex
    guard start >= 0, flac.count >= start + 8, flac[base + start..<base + start + 4] == Data("fLaC".utf8) else {
      return nil
    }
    var offset = start + 4
    var blocks: [Block] = []
    var last = false
    while !last {
      guard offset + 4 <= flac.count else { return nil }
      let header = flac[base + offset]
      last = header & 0x80 != 0
      let length = Int(flac[base + offset + 1]) << 16 | Int(flac[base + offset + 2]) << 8
        | Int(flac[base + offset + 3])
      let bodyStart = offset + 4
      guard bodyStart + length <= flac.count else { return nil }
      blocks.append(Block(type: header & 0x7F, body: Data(flac[base + bodyStart..<base + bodyStart + length])))
      offset = bodyStart + length
    }
    guard blocks.first?.type == 0 else { return nil }  // STREAMINFO comes first
    return (blocks, offset)
  }

  /// "fLaC" and the blocks, with the last-block flag on the last one.
  static func metadata(_ blocks: [Block]) -> Data {
    var out = Data("fLaC".utf8)
    for (index, block) in blocks.enumerated() {
      out.append((index == blocks.count - 1 ? 0x80 : 0) | block.type)
      let n = block.body.count
      out.append(contentsOf: [UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
      out.append(block.body)
    }
    return out
  }

  /// Merges `tags` in: each non-nil field replaces its Vorbis comment(s) and
  /// every other comment stays; artwork replaces the front-cover PICTURE(s)
  /// only. PADDING is dropped. Seek points stay valid: they are relative to the
  /// first audio frame.
  static func merged(_ blocks: [Block], with tags: AudioTags) -> [Block] {
    var blocks = blocks.filter { $0.type != 1 }
    let index = blocks.firstIndex { $0.type == 4 }
    var comment = index.flatMap { parseVorbisComment(blocks[$0].body) } ?? (vendor, [])
    for key in keys {
      guard let value = tags[keyPath: key.path] else { continue }
      let matches = { (field: String) in key.replace.contains(fieldKey(field)) }
      let at = comment.fields.firstIndex(where: matches) ?? comment.fields.count
      comment.fields.removeAll(where: matches)
      comment.fields.insert("\(key.write)=\(value)", at: min(at, comment.fields.count))
    }
    let body = vorbisComment(vendor: comment.vendor, fields: comment.fields)
    if body.count < 1 << 24 {
      if let index { blocks[index].body = body } else { blocks.append(Block(type: 4, body: body)) }
    }

    if let artwork = tags.artwork {
      let picture = picture(artwork, mime: tags.artworkMIMEType)
      let isCover = { (block: Block) in block.type == 6 && parsePicture(block.body)?.type == 3 }
      if picture.count < 1 << 24 {
        let at = blocks.firstIndex(where: isCover) ?? blocks.count
        blocks.removeAll(where: isCover)
        blocks.insert(Block(type: 6, body: picture), at: min(at, blocks.count))
      }
    }
    return blocks
  }

  /// Rewrites `flac` (a whole file in memory) with `tags` merged in.
  static func retag(_ flac: Data, with tags: AudioTags) throws -> Data {
    guard let (blocks, audioStart) = blocks(in: flac) else {
      throw AudioExportError.encoder("The FLAC encoder wrote something that isn't FLAC.")
    }
    var out = metadata(merged(blocks, with: tags))
    out.append(flac[(flac.startIndex + audioStart)...])
    return out
  }

  static func audioTags(_ blocks: [Block]) -> AudioTags {
    var tags = AudioTags()
    if let body = blocks.first(where: { $0.type == 4 })?.body, let comment = parseVorbisComment(body) {
      func value(_ names: String...) -> String? {
        for name in names {
          let values = comment.fields.filter { fieldKey($0) == name }
            .map { String($0.drop { $0 != "=" }.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
          if !values.isEmpty { return values.joined(separator: "; ") }
        }
        return nil
      }
      tags.title = value("TITLE")
      tags.artist = value("ARTIST")
      tags.album = value("ALBUM")
      tags.genre = value("GENRE")
      tags.year = value("DATE", "YEAR")
      tags.label = value("LABEL", "ORGANIZATION", "PUBLISHER")
      tags.isrc = value("ISRC")
      tags.comment = value("COMMENT", "DESCRIPTION")
      tags.bpm = value("BPM", "TEMPO")
      tags.key = value("INITIALKEY", "KEY")
    }
    let pictures = blocks.filter { $0.type == 6 }.compactMap { parsePicture($0.body) }
    if let art = (pictures.first { $0.type == 3 } ?? pictures.first)?.data, !art.isEmpty { tags.artwork = art }
    return tags
  }

  // MARK: Block bodies

  static func vorbisComment(vendor: String, fields: [String]) -> Data {
    var body = littleEndian32(UInt32(vendor.utf8.count))
    body.append(contentsOf: Array(vendor.utf8))
    body.append(littleEndian32(UInt32(fields.count)))
    for field in fields {
      body.append(littleEndian32(UInt32(field.utf8.count)))
      body.append(contentsOf: Array(field.utf8))
    }
    return body
  }

  static func parseVorbisComment(_ body: Data) -> (vendor: String, fields: [String])? {
    let b = [UInt8](body)
    var pos = 0
    func u32() -> Int? {
      guard pos + 4 <= b.count else { return nil }
      defer { pos += 4 }
      return Int(b[pos]) | Int(b[pos + 1]) << 8 | Int(b[pos + 2]) << 16 | Int(b[pos + 3]) << 24
    }
    func string() -> String? {
      guard let n = u32(), pos + n <= b.count else { return nil }
      defer { pos += n }
      return String(decoding: b[pos..<pos + n], as: UTF8.self)
    }
    guard let vendor = string(), let count = u32() else { return nil }
    var fields: [String] = []
    for _ in 0..<count {
      guard let field = string() else { return nil }
      fields.append(field)
    }
    return (vendor, fields)
  }

  /// "title=x" → "TITLE".
  private static func fieldKey(_ field: String) -> String {
    String(field.prefix { $0 != "=" }).uppercased()
  }

  /// PICTURE (type 6) body, front cover; dimensions left 0 (allowed, "unknown").
  static func picture(_ artwork: Data, mime: String) -> Data {
    var body = bigEndian32(3)
    body.append(bigEndian32(UInt32(mime.utf8.count)))
    body.append(contentsOf: Array(mime.utf8))
    body.append(bigEndian32(0))  // description
    for _ in 0..<4 { body.append(bigEndian32(0)) }  // width, height, depth, colours
    body.append(bigEndian32(UInt32(artwork.count)))
    body.append(artwork)
    return body
  }

  /// PICTURE: (picture type, image bytes).
  static func parsePicture(_ body: Data) -> (type: UInt32, data: Data)? {
    let b = [UInt8](body)
    var pos = 0
    func u32() -> Int? {
      guard pos + 4 <= b.count else { return nil }
      defer { pos += 4 }
      return Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
    }
    guard let type = u32(), let mime = u32() else { return nil }
    pos += mime
    guard let desc = u32() else { return nil }
    pos += desc + 16
    guard let length = u32(), pos + length <= b.count else { return nil }
    return (UInt32(type), Data(b[pos..<pos + length]))
  }
}

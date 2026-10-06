import AVFoundation
import Foundation

/// The tags DJ Tools copies from a source track onto its results.
public struct AudioTags: Sendable, Equatable {
  public var title: String?
  public var artist: String?
  public var album: String?
  /// JPEG or PNG bytes.
  public var artwork: Data?

  public init(title: String? = nil, artist: String? = nil, album: String? = nil, artwork: Data? = nil) {
    self.title = title
    self.artist = artist
    self.album = album
    self.artwork = artwork
  }

  public var isEmpty: Bool { title == nil && artist == nil && album == nil && artwork == nil }

  /// The same tags with `suffix` on the title (" (Vocals)", " (Repaired)"), using
  /// `fallbackTitle` (usually the file name) when the source had none.
  public func suffixingTitle(_ suffix: String, fallbackTitle: String) -> AudioTags {
    var copy = self
    let base = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.title = ((base?.isEmpty == false ? base : nil) ?? fallbackTitle) + suffix
    return copy
  }

  /// "image/png" or "image/jpeg", from the bytes.
  var artworkMIMEType: String {
    guard let artwork, artwork.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return "image/jpeg" }
    return "image/png"
  }

  /// Reads title, artist, album and artwork with AVFoundation (ID3 in MP3 and AIFF,
  /// iTunes atoms in M4A, …). Missing fields stay nil; never throws.
  public static func read(from url: URL) async -> AudioTags {
    let asset = AVURLAsset(url: url)
    guard let items = try? await asset.load(.commonMetadata), !items.isEmpty else { return AudioTags() }
    func first(_ key: AVMetadataKey) -> AVMetadataItem? {
      AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first
    }
    func string(_ key: AVMetadataKey) async -> String? {
      guard let item = first(key), let value = try? await item.load(.stringValue) else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    var tags = AudioTags()
    tags.title = await string(.commonKeyTitle)
    tags.artist = await string(.commonKeyArtist)
    tags.album = await string(.commonKeyAlbumName)
    if let item = first(.commonKeyArtwork), let data = try? await item.load(.dataValue), !data.isEmpty {
      tags.artwork = data
    }
    return tags
  }
}

// MARK: - ID3v2.3 (MP3, and the AIFF "ID3 " chunk)

enum ID3v2 {
  /// A complete ID3v2.3 tag: TIT2, TPE1, TALB and an APIC front cover.
  static func tag(_ tags: AudioTags) -> Data {
    var frames = Data()
    if let title = tags.title { frames.append(textFrame("TIT2", title)) }
    if let artist = tags.artist { frames.append(textFrame("TPE1", artist)) }
    if let album = tags.album { frames.append(textFrame("TALB", album)) }
    if let artwork = tags.artwork {
      var body = Data([0x00])  // ISO-8859-1 description
      body.append(contentsOf: Array(tags.artworkMIMEType.utf8)); body.append(0)
      body.append(0x03)  // front cover
      body.append(0)  // empty description
      body.append(artwork)
      frames.append(frame("APIC", body))
    }
    var out = Data("ID3".utf8)
    out.append(contentsOf: [0x03, 0x00, 0x00])  // v2.3.0, no flags
    out.append(syncsafe(UInt32(frames.count)))
    out.append(frames)
    return out
  }

  private static func textFrame(_ id: String, _ text: String) -> Data {
    var body = Data()
    if text.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
      body.append(0x00)  // ISO-8859-1 (plain ASCII here)
      body.append(contentsOf: Array(text.utf8))
    } else {
      body.append(0x01)  // UTF-16 with BOM
      body.append(contentsOf: [0xFF, 0xFE])
      for unit in text.utf16 { body.append(UInt8(unit & 0xFF)); body.append(UInt8(unit >> 8)) }
    }
    return frame(id, body)
  }

  private static func frame(_ id: String, _ body: Data) -> Data {
    var out = Data(id.utf8)
    out.append(bigEndian32(UInt32(body.count)))  // v2.3: plain 32-bit size
    out.append(contentsOf: [0x00, 0x00])
    out.append(body)
    return out
  }

  private static func syncsafe(_ value: UInt32) -> Data {
    Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
  }
}

func bigEndian32(_ value: UInt32) -> Data {
  Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

func littleEndian32(_ value: UInt32) -> Data {
  Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
}

// MARK: - FLAC metadata blocks

enum FLACTags {
  static let vendor = "DJ Tools (Core Audio FLAC)"

  /// VORBIS_COMMENT (type 4) body.
  static func vorbisComment(_ tags: AudioTags) -> Data {
    var fields: [String] = []
    if let title = tags.title { fields.append("TITLE=\(title)") }
    if let artist = tags.artist { fields.append("ARTIST=\(artist)") }
    if let album = tags.album { fields.append("ALBUM=\(album)") }
    var body = littleEndian32(UInt32(vendor.utf8.count))
    body.append(contentsOf: Array(vendor.utf8))
    body.append(littleEndian32(UInt32(fields.count)))
    for field in fields {
      body.append(littleEndian32(UInt32(field.utf8.count)))
      body.append(contentsOf: Array(field.utf8))
    }
    return body
  }

  /// PICTURE (type 6) body, front cover; dimensions left 0 (allowed, "unknown").
  static func picture(_ tags: AudioTags) -> Data? {
    guard let artwork = tags.artwork else { return nil }
    let mime = tags.artworkMIMEType
    var body = bigEndian32(3)
    body.append(bigEndian32(UInt32(mime.utf8.count)))
    body.append(contentsOf: Array(mime.utf8))
    body.append(bigEndian32(0))  // description
    for _ in 0..<4 { body.append(bigEndian32(0)) }  // width, height, depth, colours
    body.append(bigEndian32(UInt32(artwork.count)))
    body.append(artwork)
    return body
  }

  /// Rewrites `flac` (a whole file in memory) with these tags: keeps STREAMINFO,
  /// SEEKTABLE and the like, drops any existing VORBIS_COMMENT, PICTURE and
  /// PADDING, and appends ours. Seek points stay valid: they are relative to the
  /// first audio frame.
  static func retag(_ flac: Data, with tags: AudioTags) throws -> Data {
    guard flac.count > 8, flac.prefix(4) == Data("fLaC".utf8) else {
      throw AudioExportError.encoder("The FLAC encoder wrote something that isn't FLAC.")
    }
    var offset = 4
    var kept: [(type: UInt8, body: Data)] = []
    var last = false
    while !last {
      guard offset + 4 <= flac.count else { throw AudioExportError.encoder("Truncated FLAC metadata.") }
      let header = flac[flac.startIndex + offset]
      last = header & 0x80 != 0
      let type = header & 0x7F
      let length = Int(flac[flac.startIndex + offset + 1]) << 16 | Int(flac[flac.startIndex + offset + 2]) << 8
        | Int(flac[flac.startIndex + offset + 3])
      let start = flac.startIndex + offset + 4
      guard start + length <= flac.endIndex else { throw AudioExportError.encoder("Truncated FLAC metadata.") }
      if ![1, 4, 6].contains(type) { kept.append((type, flac[start..<start + length])) }
      offset += 4 + length
    }
    kept.append((4, vorbisComment(tags)))
    if let picture = picture(tags), picture.count < 1 << 24 { kept.append((6, picture)) }

    var out = Data("fLaC".utf8)
    for (index, block) in kept.enumerated() {
      let isLast = index == kept.count - 1
      out.append((isLast ? 0x80 : 0) | block.type)
      let n = block.body.count
      out.append(contentsOf: [UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
      out.append(block.body)
    }
    out.append(flac[(flac.startIndex + offset)...])
    return out
  }
}

import AVFoundation
import Foundation

/// The tags DJ Kit copies from a source track onto its results, and writes
/// into a track once it's identified.
public struct AudioTags: Sendable, Equatable {
  public var title: String?
  public var artist: String?
  public var album: String?
  /// JPEG or PNG bytes.
  public var artwork: Data?
  public var genre: String?
  /// "2024" or "2024-05-17". ID3v2.3 keeps only the year.
  public var year: String?
  /// Record label (ID3 TPUB, Vorbis LABEL).
  public var label: String?
  public var isrc: String?
  public var comment: String?
  /// Tag text as stored ("124", "123.5"); ID3 TBPM, Vorbis BPM, M4A tmpo.
  public var bpm: String?
  /// Tag text as stored ("8A", "Am"); ID3 TKEY, Vorbis INITIALKEY.
  public var key: String?

  public init(
    title: String? = nil, artist: String? = nil, album: String? = nil, artwork: Data? = nil,
    genre: String? = nil, year: String? = nil, label: String? = nil, isrc: String? = nil, comment: String? = nil,
    bpm: String? = nil, key: String? = nil
  ) {
    self.title = title
    self.artist = artist
    self.album = album
    self.artwork = artwork
    self.genre = genre
    self.year = year
    self.label = label
    self.isrc = isrc
    self.comment = comment
    self.bpm = bpm
    self.key = key
  }

  public var isEmpty: Bool {
    title == nil && artist == nil && album == nil && artwork == nil && genre == nil && year == nil
      && label == nil && isrc == nil && comment == nil && bpm == nil && key == nil
  }

  /// The same tags with `suffix` on the title (" (Vocals)", " (Repaired)"), using
  /// `fallbackTitle` (usually the file name) when the source had none.
  public func suffixingTitle(_ suffix: String, fallbackTitle: String) -> AudioTags {
    var copy = self
    let base = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.title = ((base?.isEmpty == false ? base : nil) ?? fallbackTitle) + suffix
    return copy
  }

  /// BPM and key as written: trimmed, nil when empty.
  var bpmText: String? { Self.trimmed(bpm) }
  var keyText: String? { Self.trimmed(key) }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  /// "image/png" or "image/jpeg", from the bytes.
  var artworkMIMEType: String {
    guard let artwork, artwork.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return "image/jpeg" }
    return "image/png"
  }

  /// Reads the tags: our own parser for ID3 (MP3, and the AIFF / WAV chunk) and
  /// FLAC Vorbis comments, AVFoundation for the rest (iTunes atoms in M4A, …)
  /// and for title, artist, album and artwork it didn't find. Missing fields
  /// stay nil; never throws.
  public static func read(from url: URL) async -> AudioTags {
    let native = TagFile.read(url)
    var tags = native ?? AudioTags()
    let asset = AVURLAsset(url: url)

    if tags.title == nil || tags.artist == nil || tags.album == nil || tags.artwork == nil,
      let items = try? await asset.load(.commonMetadata), !items.isEmpty
    {
      func item(_ key: AVMetadataKey) -> AVMetadataItem? {
        AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first
      }
      if tags.title == nil { tags.title = await string(item(.commonKeyTitle)) }
      if tags.artist == nil { tags.artist = await string(item(.commonKeyArtist)) }
      if tags.album == nil { tags.album = await string(item(.commonKeyAlbumName)) }
      if tags.artwork == nil, let item = item(.commonKeyArtwork),
        let data = try? await item.load(.dataValue), !data.isEmpty
      {
        tags.artwork = data
      }
    }

    // Files we parse ourselves are done; AVFoundation's ID3 comments include iTunNORM and the like.
    guard native == nil, let items = try? await asset.load(.metadata), !items.isEmpty else { return tags }
    func first(_ ids: [AVMetadataIdentifier]) async -> String? {
      for id in ids {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
          if let value = await string(item) { return value }
        }
      }
      return nil
    }
    tags.genre = await first([.iTunesMetadataUserGenre, .quickTimeMetadataGenre, .id3MetadataContentType])
      .flatMap(ID3Tag.genreName)
    if tags.genre == nil,
      let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataPredefinedGenre).first,
      let data = try? await item.load(.dataValue), data.count >= 2
    {
      let n = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
      if n >= 1, n <= id3v1Genres.count { tags.genre = id3v1Genres[n - 1] }
    }
    tags.year = await first([
      .iTunesMetadataReleaseDate, .quickTimeMetadataYear, .id3MetadataRecordingTime, .id3MetadataYear,
      .commonIdentifierCreationDate,
    ])
    tags.label = await first([
      M4AKeys.label, .iTunesMetadataPublisher, .iTunesMetadataRecordCompany, .id3MetadataPublisher,
      .quickTimeMetadataPublisher,
    ])
    tags.isrc = await first([M4AKeys.isrc, .id3MetadataInternationalStandardRecordingCode])
    tags.comment = await first([.iTunesMetadataUserComment, .quickTimeMetadataComment])
    if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataBeatsPerMin).first,
      let n = try? await item.load(.numberValue)?.intValue, n > 0
    {
      tags.bpm = String(n)
    }
    tags.key = await first([M4AKeys.initialKey, M4AKeys.initialKeyUpper])
    return tags
  }

  private static func string(_ item: AVMetadataItem?) async -> String? {
    guard let item, let value = try? await item.load(.stringValue) else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// iTunes free-form ("----:com.apple.iTunes:…") atoms, as AVFoundation names them.
enum M4AKeys {
  static let label = AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.LABEL")
  static let isrc = AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.ISRC")
  /// Mixed In Key and Rekordbox write it lower case.
  static let initialKey = AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.initialkey")
  static let initialKeyUpper = AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.INITIALKEY")
}

func bigEndian32(_ value: UInt32) -> Data {
  Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

func littleEndian32(_ value: UInt32) -> Data {
  Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
}

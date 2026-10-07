import Foundation

/// The file types DJ Kit can write its results as.
///
/// Raw values are stable: they are what Settings stores and what
/// `-selfTestFormat` takes ("aiff", "wav", "flac", "mp3-320", "mp3-256", "mp3-192").
public enum AudioFileFormat: String, Sendable, Codable, CaseIterable, Identifiable {
  /// 24-bit (16-bit for 16-bit sources) PCM AIFF with an ID3 chunk. Best for Rekordbox.
  case aiff
  /// 24-bit (or 16-bit) PCM WAV. No tags.
  case wav
  /// 24-bit (or 16-bit) FLAC with Vorbis comments and a cover picture.
  case flac
  /// LAME CBR, joint stereo, highest quality, 44.1 kHz, with an ID3v2.3 tag.
  case mp3_320 = "mp3-320"
  case mp3_256 = "mp3-256"
  case mp3_192 = "mp3-192"

  public var id: String { rawValue }

  public var fileExtension: String {
    switch self {
    case .aiff: "aiff"
    case .wav: "wav"
    case .flac: "flac"
    case .mp3_320, .mp3_256, .mp3_192: "mp3"
    }
  }

  public var isLossless: Bool { mp3BitrateKbps == nil }

  public var mp3BitrateKbps: Int? {
    switch self {
    case .mp3_320: 320
    case .mp3_256: 256
    case .mp3_192: 192
    case .aiff, .wav, .flac: nil
    }
  }

  /// Whether title/artist/album/artwork are written into the file.
  public var writesTags: Bool { self != .wav }

  /// "AIFF", "WAV", "FLAC", "MP3 320 kbps".
  public var title: String {
    if let kbps = mp3BitrateKbps { return "MP3 \(kbps) kbps" }
    return rawValue.uppercased()
  }

  /// "AIFF", "MP3 320": for tight spots.
  public var shortTitle: String {
    if let kbps = mp3BitrateKbps { return "MP3 \(kbps)" }
    return rawValue.uppercased()
  }
}

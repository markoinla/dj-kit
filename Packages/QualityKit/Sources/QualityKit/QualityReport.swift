import Foundation

public enum QualityVerdict: String, Sendable, Codable {
    case lossless, goodLossy, lowQuality, fakeLossless, unknown
}

public struct QualityReport: Sendable, Codable, Equatable {
    public var url: URL
    /// File extension, lowercased: "mp3", "flac", "wav", "aiff", "m4a", ...
    public var container: String
    /// True when the codec inside is lossless (PCM, FLAC, ALAC) — decided by codec, not extension.
    public var isLosslessContainer: Bool
    /// Declared/estimated bitrate from the file, when it has one.
    public var declaredBitrateKbps: Int?
    public var sampleRate: Double
    public var channels: Int
    public var duration: TimeInterval
    /// Estimated spectral cutoff (where the highs stop). Nil when it could not be measured.
    public var cutoffHz: Double?
    public var verdict: QualityVerdict
    /// One line for the UI.
    public var summary: String

    public init(url: URL, container: String, isLosslessContainer: Bool, declaredBitrateKbps: Int?,
                sampleRate: Double, channels: Int, duration: TimeInterval, cutoffHz: Double?,
                verdict: QualityVerdict, summary: String) {
        self.url = url
        self.container = container
        self.isLosslessContainer = isLosslessContainer
        self.declaredBitrateKbps = declaredBitrateKbps
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
        self.cutoffHz = cutoffHz
        self.verdict = verdict
        self.summary = summary
    }
}

public enum QualityError: Error, LocalizedError, Sendable {
    case cannotOpen(URL, String)
    case emptyFile(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url, let why): return "Can't open \(url.lastPathComponent): \(why)"
        case .emptyFile(let url): return "\(url.lastPathComponent) has no audio"
        }
    }
}

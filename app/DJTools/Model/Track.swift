import Foundation

/// A dropped audio file, its quality report and what the tools made from it.
/// Persisted in `library.json` (see `LibraryStore`).
struct Track: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var url: URL
    var addedAt: Date
    var fileSize: Int64?
    var quality: DJQualityReport?
    /// The last quality check's failure.
    var qualityError: String?
    /// Measured on demand (the Normalize card, or a normalize run), never
    /// by the automatic quality check: it takes a full decode.
    var loudness: DJLoudnessReport?
    var loudnessError: String?
    var results: [TrackResult]

    init(url: URL, addedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        results = []
    }

    /// The file name without its extension.
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// "mp3", "flac", …
    var container: String { url.pathExtension.lowercased() }
    var verdict: DJQualityVerdict? { quality?.verdict }

    /// Lossy-sounding audio: Apollo is the suggested tool.
    var needsRepair: Bool {
        verdict == .lowQuality || verdict == .fakeLossless
    }

    /// A very low-quality source (≤ 96 kbps lossy, or recorded below
    /// 44.1 kHz): Apollo has little to work from, so results vary.
    var isVeryLowSource: Bool {
        guard let quality else { return false }
        if quality.sampleRate > 0, quality.sampleRate < 44_100 { return true }
        if !quality.isLosslessContainer, let kbps = quality.declaredBitrateKbps, kbps <= 96 { return true }
        return false
    }

    var fileExists: Bool { FileCheck.exists(url) }

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif"]
}

/// Something a tool wrote for a track.
struct TrackResult: Identifiable, Codable, Sendable, Equatable {
    enum Kind: Codable, Sendable, Equatable {
        case stems(model: DJStemModel, folder: URL, stems: [String: URL])
        /// `normalization` when "Also normalize repaired tracks" was on.
        case repaired(output: URL, normalization: DJNormalizationPlan? = nil)
        case normalized(output: URL, plan: DJNormalizationPlan)
    }

    var id: UUID = UUID()
    var kind: Kind
    var finishedAt: Date = Date()

    /// What Reveal in Finder selects.
    var revealURL: URL {
        switch kind {
        case .stems(_, let folder, _): folder
        case .repaired(let output, _), .normalized(let output, _): output
        }
    }
}

extension DJQualityVerdict {
    /// The badge's word.
    var label: String {
        switch self {
        case .lossless: "Lossless"
        case .goodLossy: "Good"
        case .lowQuality: "Low quality"
        case .fakeLossless: "Fake lossless"
        case .unknown: "Unknown"
        }
    }

    /// A sentence for the detail pane, under the summary.
    var explanation: String {
        switch self {
        case .lossless: "Nothing to fix. The highs run all the way up."
        case .goodLossy: "A high-bitrate encode. Fine on a club system."
        case .lowQuality: "The top end is missing, and it will show on a big system. Apollo can rebuild some of it."
        case .fakeLossless: "A lossy file re-saved as lossless, so the size lies. Apollo can rebuild some of the highs."
        case .unknown: "The check couldn't tell."
        }
    }
}

enum FileCheck {
    #if DEBUG
    /// `-renderPreviews`: the fixtures' files don't exist, but should look as if they do.
    nonisolated(unsafe) static var assumeExists = false
    #endif

    static func exists(_ url: URL) -> Bool {
        #if DEBUG
        if assumeExists { return true }
        #endif
        return FileManager.default.fileExists(atPath: url.path)
    }
}

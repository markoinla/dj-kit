import Foundation

// The app's own copies of the engine packages' value types
// (docs/CONTRACTS.md). Field for field the same as the contract, prefixed
// `DJ` so they never clash with the packages' names once those are linked:
// an adapter maps `QualityKit.QualityReport` → `DJQualityReport` and so on
// (see Engines/README.md).

// MARK: - QualityKit

/// Mirrors `QualityKit.QualityVerdict`.
enum DJQualityVerdict: String, Sendable, Codable, CaseIterable {
    case lossless, goodLossy, lowQuality, fakeLossless, unknown
}

/// Mirrors `QualityKit.QualityReport`.
struct DJQualityReport: Sendable, Codable, Equatable {
    var url: URL
    /// "mp3", "flac", "wav", "aiff", "m4a", ...
    var container: String
    var isLosslessContainer: Bool
    /// From the file, when it has one.
    var declaredBitrateKbps: Int?
    var sampleRate: Double
    var channels: Int
    var duration: TimeInterval
    /// Estimated spectral cutoff (where the highs stop).
    var cutoffHz: Double?
    var verdict: DJQualityVerdict
    /// One line for the UI, e.g. "Cuts off at 16 kHz — likely a 128 kbps MP3".
    var summary: String
}

// MARK: - StemsKit

/// Mirrors `StemsKit.StemModel` (same cases and raw values).
enum DJStemModel: String, Sendable, Codable, CaseIterable, Identifiable {
    case htdemucs, htdemucsFT, htdemucs6s

    var id: Self { self }

    /// The model's own name, as Demucs spells it.
    var modelName: String {
        switch self {
        case .htdemucs: "htdemucs"
        case .htdemucsFT: "htdemucs_ft"
        case .htdemucs6s: "htdemucs_6s"
        }
    }

    /// What the picker says.
    var title: String {
        switch self {
        case .htdemucs: "Standard"
        case .htdemucsFT: "Fine-tuned"
        case .htdemucs6s: "6 stems"
        }
    }

    var helper: String {
        switch self {
        case .htdemucs: "Vocals, drums, bass and other. The quickest."
        case .htdemucsFT: "Vocals, drums, bass and other, cleaner. About 4× slower."
        case .htdemucs6s: "Adds guitar and piano to the four."
        }
    }

    /// The stems this model writes, in the order the UI lists them.
    var stemNames: [String] {
        switch self {
        case .htdemucs, .htdemucsFT: ["vocals", "drums", "bass", "other"]
        case .htdemucs6s: ["vocals", "drums", "bass", "guitar", "piano", "other"]
        }
    }
}

/// Mirrors `StemsKit.StemResult`: "vocals", "drums", "bass", "other"
/// (, "guitar", "piano") → the written WAV.
struct DJStemResult: Sendable, Codable, Equatable {
    var stems: [String: URL]
}

// MARK: - Apollo

/// Apollo's setup: the model weights downloaded and converted, or not.
enum DJApolloSetupState: Sendable, Equatable {
    case notInstalled
    case installing(String)
    case ready
    case failed(String)

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }
}

// MARK: - LoudnessKit

/// Mirrors `LoudnessKit.LoudnessReport` (BS.1770-4 / EBU R128). Silence is
/// `-infinity` (`LibraryStore` writes it as a string).
struct DJLoudnessReport: Sendable, Codable, Equatable {
    var integratedLUFS: Double
    var truePeakDBTP: Double
    var samplePeakDBFS: Double
    var loudnessRangeLU: Double?
    var duration: TimeInterval
    var sampleRate: Double
    var channels: Int

    var isSilent: Bool { !integratedLUFS.isFinite }
}

/// Mirrors `LoudnessKit.NormalizationPlan`: a pure gain change, capped so the
/// true peak stays at or below the ceiling.
struct DJNormalizationPlan: Sendable, Codable, Equatable {
    var targetLUFS: Double
    var ceilingDBTP: Double
    var gainDB: Double
    var limitedByCeiling: Bool
    var resultingLUFS: Double
    var resultingTruePeakDBTP: Double
}

/// Where normalization aims: Settings' target loudness and true-peak ceiling.
struct DJLoudnessTarget: Sendable, Codable, Equatable, Hashable {
    var lufs: Double
    var ceilingDBTP: Double
}

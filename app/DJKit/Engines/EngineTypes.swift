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

// MARK: - AnalysisKit

/// Mirrors `AnalysisKit.MusicalKey`: pitch class 0 = C … 11 = B. Spelling and
/// parsing come from the package (`RealEngines.swift`).
struct DJMusicalKey: Sendable, Codable, Hashable {
    var tonic: Int
    var isMinor: Bool
}

/// Mirrors `AnalysisKit.KeyEstimate`.
struct DJKeyEstimate: Sendable, Codable, Equatable {
    var key: DJMusicalKey
    /// How far the best key leads the runner-up (0…1). Debug only.
    var margin: Double
}

/// Mirrors `AnalysisKit.TempoEstimate`: raw, folded only for display and tags.
struct DJTempoEstimate: Sendable, Codable, Equatable {
    var rawBPM: Double
    var beatCount: Int
    /// Coefficient of variation of the beat interval.
    var stability: Double
}

/// `AnalysisKit.MusicalAnalyzerError.modelUnavailable`: the tempo model
/// couldn't be downloaded or checked (offline, server error). Transient: not
/// remembered per track, the next try sets it up again.
struct DJAnalysisModelUnavailable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Mirrors `AnalysisKit.MusicalAnalysis`.
struct DJMusicalAnalysis: Sendable, Codable, Equatable {
    /// Nil: no beats found.
    var tempo: DJTempoEstimate?
    /// Nil: silent or atonal.
    var key: DJKeyEstimate?
    var duration: TimeInterval
}

// MARK: - Track ID

/// What Track ID found for a file: Shazam's match, filled in from the Apple
/// Music catalog (album, label, release date, artwork).
struct DJTrackIdentity: Sendable, Codable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var label: String?
    var genre: String?
    /// "YYYY-MM-DD".
    var releaseDate: String?
    var isrc: String?
    /// The catalog release's length.
    var durationSeconds: TimeInterval?
    var artworkURL: URL?
    var appleMusicURL: URL?
    var shazamURL: URL?
    /// Listens that matched this track, of `listens`.
    var hits: Int
    var listens: Int

    var year: String? { releaseDate.map { String($0.prefix(4)) } }
    /// Two listens or more agree.
    var isStrong: Bool { hits >= 2 }
}

/// Which stems a separation keeps. Demucs always makes all of them; this
/// picks the files written. "instrumental" is every stem but the vocals,
/// mixed back together.
enum DJStemChoice: Sendable, Codable, Hashable {
    case all
    case acapellaInstrumental
    case custom(Set<String>)

    static let instrumental = "instrumental"

    /// The outputs for `model`, in the UI's order (never empty).
    func outputs(for model: DJStemModel) -> [String] {
        let available = model.stemNames + [Self.instrumental]
        let picked: Set<String> = switch self {
        case .all: Set(model.stemNames)
        case .acapellaInstrumental: ["vocals", Self.instrumental]
        case .custom(let names): names
        }
        let outputs = available.filter(picked.contains)
        return outputs.isEmpty ? model.stemNames : outputs
    }
}

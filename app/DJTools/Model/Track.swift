import AudioExport
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
    /// Measured on demand (the Normalize row, or a Process run), never
    /// by the automatic quality check: it takes a full decode.
    var loudness: DJLoudnessReport?
    var loudnessError: String?
    /// Track ID's match (a suggestion until applied), nil when nothing
    /// matched or it hasn't run.
    var identity: DJTrackIdentity?
    /// When Track ID last finished (match or not).
    var identifiedAt: Date?
    var identityStatus: IdentityStatus?
    var identifyError: String?
    /// BPM and key, raw (folded for display and tags by `bpmGenres`).
    var analysis: DJMusicalAnalysis?
    var analysisError: String?
    /// The file's own BPM, key and genre tags when it was analyzed.
    var fileTags: FileMusicalTags?
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
    /// "MP3 128", "FLAC": the file type, with the bitrate when lossy.
    var formatLabel: String {
        let type = DJFormat.container(container)
        guard let quality, !quality.isLosslessContainer, let kbps = quality.declaredBitrateKbps else { return type }
        return "\(type) \(kbps)"
    }

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

    /// The latest result as Process files (an older one-tool result too).
    var latestResult: (result: TrackResult, files: ProcessedFiles)? {
        results.last.map { ($0, $0.kind.files) }
    }

    var latestFiles: ProcessedFiles? { latestResult?.files }

    /// A match waiting for Apply or Not This Track.
    var hasPendingIdentity: Bool { identity != nil && identityStatus == nil }

    /// The match's length is far from the file's: likely another mix or edit
    /// (the tags are still the song's).
    var identityLengthMismatch: Bool {
        guard let expected = identity?.durationSeconds, let actual = quality?.duration, expected > 0, actual > 0 else { return false }
        return abs(expected - actual) > max(15, 0.08 * actual)
    }

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif"]
}

extension Track {
    /// What BPM is folded for: the file's own genre tag and Track ID's
    /// (unless turned down); slow when either is (`BPMRange.forGenres`).
    var bpmGenres: [String?] {
        [fileTags?.genre, identityStatus == .dismissed ? nil : identity?.genre]
    }

    /// The detected BPM, folded; nil before analysis or when no beats were found.
    var detectedBPM: Double? { analysis?.tempo?.bpm(genres: bpmGenres) }

    /// "124 BPM · 8A · Am" ("~96 BPM" when the tempo isn't steady); what
    /// was found, nil when nothing was.
    var musicalReadout: String? {
        guard let analysis else { return nil }
        var parts: [String] = []
        if let tempo = analysis.tempo, let bpm = detectedBPM {
            parts.append("\(tempo.isSteady ? "" : "~")\(DJBPM.string(bpm)) BPM")
        }
        if let key = analysis.key?.key { parts += [key.camelot, key.musical] }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "tag: 123 · 9A · Em": the file's own BPM and key where they disagree
    /// with what was detected (more than 0.5 BPM apart, another key).
    var musicalTagMismatch: String? {
        guard let analysis, let tags = fileTags else { return nil }
        var parts: [String] = []
        if let tagged = tags.bpmValue, let bpm = detectedBPM, abs(bpm - tagged) > 0.5 {
            parts.append(DJBPM.string(tagged))
        }
        if let text = tags.key?.trimmed, !text.isEmpty, let detected = analysis.key?.key {
            if let tagged = DJMusicalKey(parsing: text) {
                if tagged != detected { parts += [tagged.camelot, tagged.musical] }
            } else {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : "tag: " + parts.joined(separator: " · ")
    }
}

/// A file's own BPM, key and genre tags, as written.
struct FileMusicalTags: Codable, Sendable, Equatable {
    var bpm: String?
    var key: String?
    /// As first read: Apply may replace the file's genre with Track ID's,
    /// but folding still counts the original (`AppModel.applyIdentity`).
    var genre: String?

    init(_ tags: AudioTags) {
        bpm = tags.bpm
        key = tags.key
        genre = tags.genre
    }

    /// The BPM tag as a number; nil when missing, zero or not a number.
    var bpmValue: Double? { AudioTags.bpmValue(bpm) }
}

/// Where a track stands, for the sidebar's groups and the detail pane.
enum TrackStage: Sendable {
    /// A Process run is queued or running.
    case processing
    /// Not processed yet, or the last run failed.
    case ready
    /// The latest result is there.
    case done
}

/// What happened to a Track ID match.
enum IdentityStatus: String, Codable, Sendable {
    /// Tags written (and the file renamed, when that's on).
    case applied
    /// "Not This Track".
    case dismissed
}

/// What a Process run saved: the finished track (when it repaired or
/// normalized) and the stems folder (when it separated).
struct ProcessedFiles: Codable, Sendable, Equatable {
    var output: URL?
    var repaired: Bool
    var normalization: DJNormalizationPlan?
    var stemModel: DJStemModel?
    var stemsFolder: URL?
    var stems: [String: URL]?
}

/// Something a tool wrote for a track.
struct TrackResult: Identifiable, Codable, Sendable, Equatable {
    enum Kind: Codable, Sendable, Equatable {
        case processed(ProcessedFiles)
        // Before Process: one tool per run. Kept so older libraries still load.
        case stems(model: DJStemModel, folder: URL, stems: [String: URL])
        case repaired(output: URL, normalization: DJNormalizationPlan? = nil)
        case normalized(output: URL, plan: DJNormalizationPlan)

        /// The same files as a Process run's.
        var files: ProcessedFiles {
            switch self {
            case .processed(let files): files
            case .stems(let model, let folder, let stems):
                ProcessedFiles(repaired: false, stemModel: model, stemsFolder: folder, stems: stems)
            case .repaired(let output, let plan): ProcessedFiles(output: output, repaired: true, normalization: plan)
            case .normalized(let output, let plan): ProcessedFiles(output: output, repaired: false, normalization: plan)
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var finishedAt: Date = Date()

    /// What Reveal in Finder selects.
    var revealURL: URL {
        switch kind {
        case .processed(let files): files.output ?? files.stemsFolder ?? URL.musicDirectory
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

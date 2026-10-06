import AudioExport
import Foundation
import Observation

/// Where the app keeps things (docs/CONTRACTS.md: App Support/DJTools).
enum AppPaths {
    /// `~/Library/Application Support/DJTools/`, or `-supportDirectory <path>`
    /// (for `-selfTest` runs and testing, so they don't touch the real one).
    static var support: URL {
        if let path = LaunchArguments.value("supportDirectory") {
            return URL(filePath: path, directoryHint: .isDirectory).absoluteURL.standardizedFileURL
        }
        return URL.applicationSupportDirectory.appending(path: "DJTools", directoryHint: .isDirectory)
    }

    /// `~/Music/DJ Tools/`.
    static var defaultOutputFolder: URL {
        URL.musicDirectory.appending(path: "DJ Tools", directoryHint: .isDirectory)
    }
}

/// The track list and finished results, as `library.json` in App Support.
struct LibraryStore: Sendable {
    private struct File: Codable {
        var version = 1
        var tracks: [Track]
    }

    let url: URL

    /// Silence measures −∞ LUFS; JSON has no infinity.
    private static let floats = JSONDecoder.NonConformingFloatDecodingStrategy.convertFromString(
        positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    init(directory: URL = AppPaths.support) {
        url = directory.appending(path: "library.json")
    }

    func load() -> [Track] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = Self.floats
        return (try? decoder.decode(File.self, from: data).tracks) ?? []
    }

    func save(_ tracks: [Track]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(tracks: tracks)).write(to: url, options: .atomic)
        } catch {
            NSLog("DJTools: couldn't save the library: \(error)")
        }
    }
}

/// Settings (⌘,), in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let defaultStemModel = "defaultStemModel"
        static let stemsFormat = "stemsFormat"
        static let repairFormat = "repairFormat"
        static let normalizeFormat = "normalizeFormat"
        static let targetLUFS = "targetLUFS"
        static let ceilingDBTP = "truePeakCeilingDBTP"
        static let normalizeRepairs = "normalizeRepairs"
        static let saveFormat = "saveFormat"
        static let stemChoice = "stemChoice"
        static let identifyOnAdd = "identifyOnAdd"
        static let renameOnApply = "renameOnApply"
        static let autoApplyMatches = "autoApplyMatches"
    }

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    var defaultStemModel: DJStemModel {
        didSet { defaults.set(defaultStemModel.rawValue, forKey: Key.defaultStemModel) }
    }

    /// Settings ▸ General's "Save files as": choosing it sets every tool's
    /// file type below (each can still be changed on its own).
    var saveFormat: AudioFileFormat {
        didSet {
            defaults.set(saveFormat.rawValue, forKey: Key.saveFormat)
            stemsFormat = saveFormat
            repairFormat = saveFormat
            normalizeFormat = saveFormat
        }
    }

    /// The file type stems are saved as, unless a job picks another.
    var stemsFormat: AudioFileFormat {
        didSet { defaults.set(stemsFormat.rawValue, forKey: Key.stemsFormat) }
    }

    /// The file type Apollo repairs are saved as, unless a job picks another.
    var repairFormat: AudioFileFormat {
        didSet { defaults.set(repairFormat.rawValue, forKey: Key.repairFormat) }
    }

    /// The file type normalized copies are saved as, unless a job picks another.
    var normalizeFormat: AudioFileFormat {
        didSet { defaults.set(normalizeFormat.rawValue, forKey: Key.normalizeFormat) }
    }

    /// Normalization's target loudness, in LUFS (−8…−16).
    var targetLUFS: Double {
        didSet { defaults.set(targetLUFS, forKey: Key.targetLUFS) }
    }

    /// The true-peak ceiling the gain never pushes past, in dBTP.
    var ceilingDBTP: Double {
        didSet { defaults.set(ceilingDBTP, forKey: Key.ceilingDBTP) }
    }

    /// Normalize Apollo's output as the last step of a repair. (Never for
    /// stems: they must keep their relative levels to sum back to the mix.)
    var normalizeRepairs: Bool {
        didSet { defaults.set(normalizeRepairs, forKey: Key.normalizeRepairs) }
    }

    /// Which stems a separation keeps, unless a job picks others.
    var stemChoice: DJStemChoice {
        didSet { defaults.set(try? JSONEncoder().encode(stemChoice), forKey: Key.stemChoice) }
    }

    /// Run Track ID on every dropped track.
    var identifyOnAdd: Bool {
        didSet { defaults.set(identifyOnAdd, forKey: Key.identifyOnAdd) }
    }

    /// Apply renames the file "Artist - Title.ext" (in its own folder).
    var renameOnApply: Bool {
        didSet { defaults.set(renameOnApply, forKey: Key.renameOnApply) }
    }

    /// Apply a match without asking when the listens agree and the length fits.
    var autoApplyMatches: Bool {
        didSet { defaults.set(autoApplyMatches, forKey: Key.autoApplyMatches) }
    }

    var loudnessTarget: DJLoudnessTarget { DJLoudnessTarget(lufs: targetLUFS, ceilingDBTP: ceilingDBTP) }

    /// −8 … −16 LUFS in 1 dB steps. Club masters sit around −6 to −9; −14 is streaming level.
    static let targetChoices: [Double] = stride(from: -8.0, through: -16.0, by: -1).map { $0 }
    static let ceilingChoices: [Double] = [-0.1, -0.5, -1.0, -2.0]
    static let defaultTargetLUFS = -10.0
    static let defaultCeilingDBTP = -1.0

    /// AIFF: lossless, and Rekordbox reads its tags and artwork.
    static let defaultFormat = AudioFileFormat.aiff

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? AppPaths.defaultOutputFolder
        defaultStemModel = defaults.string(forKey: Key.defaultStemModel).flatMap(DJStemModel.init) ?? .htdemucs
        let save = defaults.string(forKey: Key.saveFormat).flatMap(AudioFileFormat.init) ?? Self.defaultFormat
        saveFormat = save
        stemsFormat = defaults.string(forKey: Key.stemsFormat).flatMap(AudioFileFormat.init) ?? save
        repairFormat = defaults.string(forKey: Key.repairFormat).flatMap(AudioFileFormat.init) ?? save
        normalizeFormat = defaults.string(forKey: Key.normalizeFormat).flatMap(AudioFileFormat.init) ?? save
        let target = defaults.object(forKey: Key.targetLUFS) as? Double
        targetLUFS = target.flatMap { Self.targetChoices.contains($0) ? $0 : nil } ?? Self.defaultTargetLUFS
        let ceiling = defaults.object(forKey: Key.ceilingDBTP) as? Double
        ceilingDBTP = ceiling.flatMap { Self.ceilingChoices.contains($0) ? $0 : nil } ?? Self.defaultCeilingDBTP
        normalizeRepairs = defaults.bool(forKey: Key.normalizeRepairs)
        stemChoice = defaults.data(forKey: Key.stemChoice).flatMap { try? JSONDecoder().decode(DJStemChoice.self, from: $0) } ?? .all
        identifyOnAdd = defaults.object(forKey: Key.identifyOnAdd) as? Bool ?? true
        renameOnApply = defaults.object(forKey: Key.renameOnApply) as? Bool ?? true
        autoApplyMatches = defaults.bool(forKey: Key.autoApplyMatches)
    }

    var isDefaultOutputFolder: Bool {
        outputFolder.standardizedFileURL.path == AppPaths.defaultOutputFolder.standardizedFileURL.path
    }
}

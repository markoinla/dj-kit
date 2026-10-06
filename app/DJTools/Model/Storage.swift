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
        static let lastRecipe = "lastRecipe"
        static let targetLUFS = "targetLUFS"
        static let ceilingDBTP = "truePeakCeilingDBTP"
        static let identifyOnAdd = "identifyOnAdd"
        static let renameOnApply = "renameOnApply"
        static let autoApplyMatches = "autoApplyMatches"
        // Before Process (read once, to seed `lastRecipe`).
        static let saveFormat = "saveFormat"
        static let defaultStemModel = "defaultStemModel"
        static let stemChoice = "stemChoice"
    }

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    /// The last Process run's steps and file type: the next one starts from
    /// it. Repair is always saved as `.suggested`.
    var lastRecipe: ProcessRecipe {
        didSet { defaults.set(try? JSONEncoder().encode(lastRecipe), forKey: Key.lastRecipe) }
    }

    /// Normalization's target loudness, in LUFS (−6…−16).
    var targetLUFS: Double {
        didSet { defaults.set(targetLUFS, forKey: Key.targetLUFS) }
    }

    /// The true-peak ceiling the gain never pushes past, in dBTP.
    var ceilingDBTP: Double {
        didSet { defaults.set(ceilingDBTP, forKey: Key.ceilingDBTP) }
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

    /// −6 … −16 LUFS in 1 dB steps. Club masters sit around −6 to −9; −14 is streaming level.
    static let targetChoices: [Double] = stride(from: -6.0, through: -16.0, by: -1).map { $0 }
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
        if let saved = defaults.data(forKey: Key.lastRecipe).flatMap({ try? JSONDecoder().decode(ProcessRecipe.self, from: $0) }) {
            lastRecipe = saved
        } else {
            var seeded = ProcessRecipe()
            seeded.format = defaults.string(forKey: Key.saveFormat).flatMap(AudioFileFormat.init) ?? Self.defaultFormat
            seeded.stemModel = defaults.string(forKey: Key.defaultStemModel).flatMap(DJStemModel.init) ?? .htdemucs
            seeded.stemChoice = defaults.data(forKey: Key.stemChoice)
                .flatMap { try? JSONDecoder().decode(DJStemChoice.self, from: $0) } ?? .all
            lastRecipe = seeded
        }
        let target = defaults.object(forKey: Key.targetLUFS) as? Double
        targetLUFS = target.flatMap { Self.targetChoices.contains($0) ? $0 : nil } ?? Self.defaultTargetLUFS
        let ceiling = defaults.object(forKey: Key.ceilingDBTP) as? Double
        ceilingDBTP = ceiling.flatMap { Self.ceilingChoices.contains($0) ? $0 : nil } ?? Self.defaultCeilingDBTP
        identifyOnAdd = defaults.object(forKey: Key.identifyOnAdd) as? Bool ?? true
        renameOnApply = defaults.object(forKey: Key.renameOnApply) as? Bool ?? true
        autoApplyMatches = defaults.bool(forKey: Key.autoApplyMatches)
    }

    var isDefaultOutputFolder: Bool {
        outputFolder.standardizedFileURL.path == AppPaths.defaultOutputFolder.standardizedFileURL.path
    }
}

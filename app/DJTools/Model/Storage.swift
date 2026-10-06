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

    init(directory: URL = AppPaths.support) {
        url = directory.appending(path: "library.json")
    }

    func load() -> [Track] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data).tracks) ?? []
    }

    func save(_ tracks: [Track]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
    }

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    var defaultStemModel: DJStemModel {
        didSet { defaults.set(defaultStemModel.rawValue, forKey: Key.defaultStemModel) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? AppPaths.defaultOutputFolder
        defaultStemModel = defaults.string(forKey: Key.defaultStemModel).flatMap(DJStemModel.init) ?? .htdemucs
    }

    var isDefaultOutputFolder: Bool {
        outputFolder.standardizedFileURL.path == AppPaths.defaultOutputFolder.standardizedFileURL.path
    }
}

import AudioExport
import Foundation

/// Runs a heavy engine and saves what it made as the chosen file type.
///
/// The engines keep writing their native output (StemsKit's 24-bit WAVs,
/// Apollo's 24-bit WAV) — here into a scratch folder on the output folder's
/// volume. `AudioExport` then converts each WAV, copies the source track's
/// title/artist/album/artwork onto it (title suffixed " (Vocals)",
/// " (Repaired)", …) and the scratch folder is removed, however the job ends.
///
/// Final names: `<out>/<track> (Stems)/<stem>.<ext>` (replacing an earlier
/// folder, as StemsKit does) and `<out>/<track> (Apollo).<ext>` (numbered
/// when taken). Used by `AppModel` and `-selfTest`.
enum ResultWriter {
    /// How much of the job's progress bar the engine gets; saving takes the rest.
    static func engineShare(_ format: AudioFileFormat) -> Double {
        format.isLossless ? 0.97 : 0.9
    }

    static func separate(
        input: URL, model: DJStemModel, format: AudioFileFormat, outputFolder: URL,
        engine: any StemSeparating,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> DJStemResult {
        let fm = FileManager.default
        let scratch = try scratchFolder(near: outputFolder)
        defer { try? fm.removeItem(at: scratch) }
        let share = engineShare(format)
        let trackName = input.deletingPathExtension().lastPathComponent

        let raw = try await engine.separate(
            input: input, model: model, outputDirectory: scratch, progress: { progress($0 * share) }
        )
        try Task.checkCancellation()
        MainHop.wrap(status)("Saving \(format.shortTitle)")

        let tags = format.writesTags ? await AudioTags.read(from: input) : nil
        let folderName = "\(trackName) (Stems)"
        let staging = scratch.appending(path: "export", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let names = model.stemNames.filter { raw.stems[$0] != nil }
            + raw.stems.keys.filter { !model.stemNames.contains($0) }.sorted()
        let onMain = MainHop.wrap(progress)
        for (index, name) in names.enumerated() {
            let count = Double(names.count)
            _ = try await AudioExporter.export(
                raw.stems[name]!, to: staging.appending(path: "\(name).\(format.fileExtension)"), format: format,
                tags: tags?.suffixingTitle(" (\(name.capitalized))", fallbackTitle: trackName),
                removingSource: true,
                progress: { onMain(share + (1 - share) * (Double(index) + $0) / count) }
            )
        }
        try Task.checkCancellation()

        let final = outputFolder.appending(path: folderName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
        return DJStemResult(stems: Dictionary(uniqueKeysWithValues: names.map {
            ($0, final.appending(path: "\($0).\(format.fileExtension)"))
        }))
    }

    static func repair(
        input: URL, format: AudioFileFormat, outputFolder: URL,
        engine: any ApolloRepairing,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let scratch = try scratchFolder(near: outputFolder)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let share = engineShare(format)
        let trackName = input.deletingPathExtension().lastPathComponent

        let raw = try await engine.repair(
            input: input, output: scratch.appending(path: "\(trackName) (Apollo).wav"),
            progress: { progress($0 * share) }, status: status
        )
        try Task.checkCancellation()
        MainHop.wrap(status)("Saving \(format.shortTitle)")

        let tags = format.writesTags ? await AudioTags.read(from: input) : nil
        let destination = AppModel.unique(outputFolder.appending(path: "\(trackName) (Apollo).\(format.fileExtension)"))
        let onMain = MainHop.wrap(progress)
        return try await AudioExporter.export(
            raw, to: destination, format: format,
            tags: tags?.suffixingTitle(" (Repaired)", fallbackTitle: trackName),
            removingSource: true,
            progress: { onMain(share + (1 - share) * $0) }
        )
    }

    /// A fresh folder for the engine's WAVs: on the output folder's volume when
    /// the system offers one (so nothing big crosses disks), else in the temp folder.
    private static func scratchFolder(near outputFolder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        if let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: outputFolder, create: true) {
            return folder
        }
        let folder = fm.temporaryDirectory.appending(path: "DJTools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

import Accelerate
import AudioExport
@preconcurrency import AVFoundation
import Foundation

/// Runs a heavy engine and saves what it made as the chosen file type.
///
/// The engines keep writing their native output (StemsKit's 24-bit WAVs,
/// Apollo's 24-bit WAV) — here into a scratch folder on the output folder's
/// volume. `AudioExport` then converts each WAV, tags it with the caller's
/// `tags` (the file's own, with Track ID's match over them; title suffixed
/// " (Vocals)", " (Repaired)", …) and the scratch folder is removed, however
/// the job ends.
///
/// Names start from "Artist - Title" when the tags have both, else the file
/// name: `<out>/<name> (Stems)/<name> (Vocals).<ext>` (replacing an earlier
/// folder), `<out>/<name> (Repaired).<ext>` and `<out>/<name> (Normalized).<ext>`
/// (numbered when taken), so stems are easy to find once they're in
/// Rekordbox or Serato. Used by `AppModel` and `-selfTest`.
///
/// Normalizing is LoudnessKit's measurement plus one gain change applied by
/// AudioExport while it encodes: no limiter, no compression, and no scratch
/// file (the source is decoded straight into the encoder).
enum ResultWriter {
    /// A saved file and, when it was normalized, the measurement and plan.
    struct Saved: Sendable {
        var url: URL
        var loudness: DJLoudnessReport?
        var plan: DJNormalizationPlan?
    }

    /// "Also normalize repaired tracks": the target and the meter.
    struct NormalizeStep: Sendable {
        var target: DJLoudnessTarget
        var meter: any LoudnessMeasuring
    }

    /// How much of a normalize job's progress bar measuring gets.
    static let measureShare = 0.25

    /// How much of the job's progress bar the engine gets; saving takes the rest.
    static func engineShare(_ format: AudioFileFormat) -> Double {
        format.isLossless ? 0.97 : 0.9
    }

    static func separate(
        input: URL, model: DJStemModel, choice: DJStemChoice = .all, format: AudioFileFormat,
        tags: AudioTags, outputFolder: URL, engine: any StemSeparating,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> DJStemResult {
        let fm = FileManager.default
        let scratch = try scratchFolder(near: outputFolder)
        defer { try? fm.removeItem(at: scratch) }
        let share = engineShare(format)
        let trackName = input.deletingPathExtension().lastPathComponent
        let base = TrackTags.fileName(TrackTags.displayName(tags, fallback: trackName))

        let raw = try await engine.separate(
            input: input, model: model, outputDirectory: scratch, progress: { progress($0 * share) }
        )
        try Task.checkCancellation()
        let onStatus = MainHop.wrap(status)

        var sources = raw.stems
        let outputs = choice.outputs(for: model)
        if outputs.contains(DJStemChoice.instrumental) {
            onStatus("Mixing the instrumental")
            let parts = model.stemNames.filter { $0 != "vocals" }.compactMap { raw.stems[$0] }
            let mixed = scratch.appending(path: "instrumental.wav")
            try await Task.detached(priority: .userInitiated) { try StemMixer.mix(parts, to: mixed) }.value
            sources[DJStemChoice.instrumental] = mixed
        }
        try Task.checkCancellation()
        onStatus("Saving \(format.shortTitle)")

        let folderName = "\(base) (Stems)"
        let staging = scratch.appending(path: "export", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let names = outputs.filter { sources[$0] != nil }
        func fileName(_ stem: String) -> String { "\(base) (\(stem.capitalized)).\(format.fileExtension)" }
        let onMain = MainHop.wrap(progress)
        for (index, name) in names.enumerated() {
            let count = Double(names.count)
            var stemTags = tags.suffixingTitle(" (\(name.capitalized))", fallbackTitle: trackName)
            stemTags.comment = "\(name.capitalized) stem · \(model.modelName)"
            _ = try await AudioExporter.export(
                sources[name]!, to: staging.appending(path: fileName(name)), format: format,
                tags: format.writesTags ? stemTags : nil,
                removingSource: true,
                progress: { onMain(share + (1 - share) * (Double(index) + $0) / count) }
            )
        }
        try Task.checkCancellation()

        let final = outputFolder.appending(path: folderName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
        return DJStemResult(stems: Dictionary(uniqueKeysWithValues: names.map {
            ($0, final.appending(path: fileName($0)))
        }))
    }

    /// Repairs with Apollo and saves `<out>/<track> (Repaired).<ext>`; with
    /// `normalize`, Apollo's output is measured and the plan's gain applied
    /// as it's saved (the last step, so the repair itself is untouched).
    static func repair(
        input: URL, format: AudioFileFormat, tags: AudioTags, outputFolder: URL,
        engine: any ApolloRepairing, normalize: NormalizeStep? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> Saved {
        let scratch = try scratchFolder(near: outputFolder)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let measuring = normalize == nil ? 0 : 0.03
        let share = engineShare(format) - measuring
        let trackName = input.deletingPathExtension().lastPathComponent
        let onStatus = MainHop.wrap(status)

        let raw = try await engine.repair(
            input: input, output: scratch.appending(path: "\(trackName) (Repaired).wav"),
            progress: { progress($0 * share) }, status: status
        )
        try Task.checkCancellation()

        var report: DJLoudnessReport?
        var plan: DJNormalizationPlan?
        if let normalize {
            onStatus("Measuring loudness")
            let measured = try await normalize.meter.measure(raw, progress: { progress(share + measuring * $0) })
            try Task.checkCancellation()
            report = measured
            plan = normalize.meter.plan(for: measured, target: normalize.target)
        }
        let base = share + measuring
        onStatus("Saving \(format.shortTitle)")

        let name = TrackTags.fileName(TrackTags.displayName(tags, fallback: trackName))
        let destination = AppModel.unique(outputFolder.appending(path: "\(name) (Repaired).\(format.fileExtension)"))
        let onMain = MainHop.wrap(progress)
        let url = try await AudioExporter.export(
            raw, to: destination, format: format,
            tags: format.writesTags ? tags.suffixingTitle(" (Repaired)", fallbackTitle: trackName) : nil,
            gainDB: plan?.gainDB ?? 0,
            removingSource: true,
            progress: { onMain(base + (1 - base) * $0) }
        )
        return Saved(url: url, loudness: report, plan: plan)
    }

    /// Measures `input`, then saves `<out>/<track> (Normalized).<ext>` with
    /// the plan's gain: the target loudness, or less when the true peak
    /// would pass the ceiling. Tags copied, title suffixed " (Normalized)".
    /// The original is never touched.
    static func normalize(
        input: URL, target: DJLoudnessTarget, format: AudioFileFormat, tags: AudioTags, outputFolder: URL,
        engine: any LoudnessMeasuring,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> Saved {
        let onStatus = MainHop.wrap(status)
        onStatus("Measuring")
        let report = try await engine.measure(input, progress: { progress($0 * measureShare) })
        try Task.checkCancellation()
        guard !report.isSilent else {
            throw AppError("This track is silent (below −70 LUFS), so there's nothing to normalize.")
        }
        let plan = engine.plan(for: report, target: target)
        onStatus("Saving \(format.shortTitle)")

        let trackName = input.deletingPathExtension().lastPathComponent
        let base = TrackTags.fileName(TrackTags.displayName(tags, fallback: trackName))
        let destination = AppModel.unique(outputFolder.appending(path: "\(base) (Normalized).\(format.fileExtension)"))
        let onMain = MainHop.wrap(progress)
        let url = try await AudioExporter.export(
            input, to: destination, format: format,
            tags: format.writesTags ? tags.suffixingTitle(" (Normalized)", fallbackTitle: trackName) : nil,
            gainDB: plan.gainDB,
            progress: { onMain(measureShare + (1 - measureShare) * $0) }
        )
        return Saved(url: url, loudness: report, plan: plan)
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

/// Sums stems back together (the instrumental: every stem but the vocals).
enum StemMixer {
    /// Writes the sample-wise sum of `sources` (same rate and channels, as
    /// Demucs writes them) to `destination` as a 32-bit float WAV. Nothing is
    /// limited: the stems sum back to the mix, which already fit.
    static func mix(_ sources: [URL], to destination: URL) throws {
        let files = try sources.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        guard let first = files.first else { throw AppError("There were no stems to mix.") }
        let format = first.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 1 << 15
        guard let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AppError("Couldn't mix the stems.")
        }
        let channels = Int(format.channelCount)
        while first.framePosition < first.length {
            try Task.checkCancellation()
            try first.read(into: sum, frameCount: chunk)
            if sum.frameLength == 0 { break }
            for file in files.dropFirst() where file.framePosition < file.length {
                try file.read(into: part, frameCount: sum.frameLength)
                let n = vDSP_Length(min(part.frameLength, sum.frameLength))
                for c in 0..<channels {
                    vDSP_vadd(sum.floatChannelData![c], 1, part.floatChannelData![c], 1, sum.floatChannelData![c], 1, n)
                }
            }
            try output.write(from: sum)
        }
    }
}

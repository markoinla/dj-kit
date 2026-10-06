import Accelerate
import AudioExport
@preconcurrency import AVFoundation
import Foundation

/// A Process run: repair → normalize → stems on one track, saved once.
///
/// Apollo writes its 24-bit WAV into a scratch folder on the output folder's
/// volume; everything after it reads that WAV, so nothing goes through a
/// lossy file between steps. Normalizing is LoudnessKit's measurement plus one
/// gain change applied while encoding (no limiter, no compression), and the
/// stems get the same gain, so they still sum back to the finished track.
/// The scratch folder is removed however the run ends.
///
/// Names start from "Artist - Title" when the tags have both, else the file
/// name, with no suffix: `<out>/<name>.<ext>` (replaced when it's there, so a
/// re-run updates the same file in Rekordbox) and
/// `<out>/<name> (Stems)/<name> (Vocals).<ext>`. What was done goes in the
/// comment tag ("Repaired · −10.0 LUFS"), after the file's own comment.
/// Used by `AppModel` and `-selfTest`.
enum ResultWriter {
    struct Steps: Sendable {
        var repair: Bool
        var normalize: DJLoudnessTarget?
        var stems: (model: DJStemModel, choice: DJStemChoice)?

        /// A finished track is written when something changed the audio.
        var writesTrack: Bool { repair || normalize != nil }
        var isEmpty: Bool { !writesTrack && stems == nil }
        /// The steps this run does, in order.
        var order: [ProcessStep] {
            [repair ? .repair : nil, normalize != nil ? .normalize : nil, stems != nil ? .stems : nil].compactMap { $0 }
        }
    }

    struct Processed: Sendable {
        var files: ProcessedFiles
        /// The measurement normalizing used (of the repaired audio when it repaired).
        var loudness: DJLoudnessReport?
    }

    /// `progress` is the whole run (0…1); `step` is the running step and its
    /// own fraction, for the stepper.
    static func process(
        input: URL, steps: Steps, format: AudioFileFormat, tags: AudioTags, outputFolder: URL, engines: Engines,
        progress: @escaping @Sendable (Double) -> Void,
        step: @escaping @Sendable (ProcessStep, Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> Processed {
        let fm = FileManager.default
        let scratch = try scratchFolder(near: outputFolder)
        defer { try? fm.removeItem(at: scratch) }
        let onStatus = MainHop.wrap(status)
        let trackName = input.deletingPathExtension().lastPathComponent
        let base = TrackTags.fileName(TrackTags.displayName(tags, fallback: trackName))

        // Rough relative durations, for one progress bar across the steps.
        let repairWeight = steps.repair ? 4.0 : 0
        let measureWeight = steps.normalize != nil ? 0.4 : 0
        let saveWeight = steps.writesTrack ? (format.isLossless ? 0.3 : 1) : 0
        let stemsWeight = steps.stems.map { $0.model == .htdemucsFT ? 8.0 : 3.0 } ?? 0
        let total = max(repairWeight + measureWeight + saveWeight + stemsWeight, 0.001)
        // Each step's stretch of that scale; saving the track is Normalize's
        // (Repair's when it doesn't normalize).
        var stretches: [ProcessStep: (start: Double, width: Double)] = [:]
        if steps.repair { stretches[.repair] = (0, repairWeight + (steps.normalize == nil ? saveWeight : 0)) }
        if steps.normalize != nil { stretches[.normalize] = (repairWeight, measureWeight + saveWeight) }
        if steps.stems != nil { stretches[.stems] = (repairWeight + measureWeight + saveWeight, stemsWeight) }
        let spans = stretches
        // A point on the scale: the run's fraction and the step's.
        let report: @Sendable ((ProcessStep, Double)) -> Void = { point in
            let (current, position) = point
            progress(position / total)
            if let span = spans[current] {
                step(current, span.width > 0 ? min(max((position - span.start) / span.width, 0), 1) : 0)
            }
        }
        // Everything through the main queue, so steps never arrive out of order.
        let onReport = MainHop.wrap(report)
        func span(_ current: ProcessStep, _ start: Double, _ width: Double) -> @Sendable (Double) -> Void {
            { onReport((current, start + width * $0)) }
        }

        var source = input
        var files = ProcessedFiles(repaired: steps.repair)
        if steps.repair {
            onReport((.repair, 0))
            source = try await engines.apollo.repair(
                input: input, output: scratch.appending(path: "repaired.wav"),
                progress: span(.repair, 0, repairWeight), status: onStatus
            )
            try Task.checkCancellation()
        }

        var measurement: DJLoudnessReport?
        var gainDB = 0.0
        if let target = steps.normalize {
            onReport((.normalize, repairWeight))
            onStatus("Measuring loudness")
            let measured = try await engines.loudness.measure(source, progress: span(.normalize, repairWeight, measureWeight))
            try Task.checkCancellation()
            measurement = measured
            // Silence has nothing to normalize; the rest of the run still happens.
            if !measured.isSilent {
                let plan = engines.loudness.plan(for: measured, target: target)
                files.normalization = plan
                gainDB = plan.gainDB
            }
        }

        let note = processNote(repaired: steps.repair, plan: files.normalization)
        if steps.writesTrack {
            onStatus("Saving \(format.shortTitle)")
            var destination = outputFolder.appending(path: "\(base).\(format.fileExtension)")
            // Never over the file being processed.
            if destination.standardizedFileURL.path == input.standardizedFileURL.path {
                destination = AppModel.unique(destination)
            }
            var trackTags = tags
            if trackTags.title?.trimmed.isEmpty ?? true { trackTags.title = trackName }
            trackTags.comment = joined(tags.comment, note)
            let start = repairWeight + measureWeight
            let saveStep: ProcessStep = steps.normalize != nil ? .normalize : .repair
            files.output = try await AudioExporter.export(
                source, to: destination, format: format,
                tags: format.writesTags ? trackTags : nil,
                gainDB: gainDB,
                progress: { onReport((saveStep, start + saveWeight * $0)) }
            )
            try Task.checkCancellation()
        }

        if let stems = steps.stems {
            let start = repairWeight + measureWeight + saveWeight
            onReport((.stems, start))
            let separated = try await separate(
                source: source, trackName: trackName, base: base, model: stems.model, choice: stems.choice,
                format: format, tags: tags, note: note, gainDB: gainDB, scratch: scratch, outputFolder: outputFolder,
                engine: engines.stems, progress: span(.stems, start, stemsWeight), status: status
            )
            files.stemModel = stems.model
            files.stemsFolder = separated.folder
            files.stems = separated.stems
        }
        return Processed(files: files, loudness: measurement)
    }

    /// Demucs on `source`, then each kept stem saved with `gainDB` into
    /// `<out>/<base> (Stems)/` (replacing an earlier folder).
    private static func separate(
        source: URL, trackName: String, base: String, model: DJStemModel, choice: DJStemChoice,
        format: AudioFileFormat, tags: AudioTags, note: String?, gainDB: Double, scratch: URL, outputFolder: URL,
        engine: any StemSeparating,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> (folder: URL, stems: [String: URL]) {
        let fm = FileManager.default
        let onStatus = MainHop.wrap(status)
        // Demucs' share of the step; the rest is mixing and saving 4–6
        // full-length files (MP3 encoding is the slower save; the
        // fine-tuned model separates about 4× slower, saving takes the same).
        let saving = (format.isLossless ? 0.3 : 0.45) * (model == .htdemucsFT ? 0.4 : 1)
        let share = 1 - saving
        onStatus("Separating stems")
        let work = scratch.appending(path: "stems", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let raw = try await engine.separate(
            input: source, model: model, outputDirectory: work, progress: { progress($0 * share) }
        )
        try Task.checkCancellation()

        var sources = raw.stems
        let outputs = choice.outputs(for: model)
        if outputs.contains(DJStemChoice.instrumental) {
            onStatus("Mixing the instrumental")
            let parts = model.stemNames.filter { $0 != "vocals" }.compactMap { raw.stems[$0] }
            let mixed = work.appending(path: "instrumental.wav")
            try await Task.detached(priority: .userInitiated) { try StemMixer.mix(parts, to: mixed) }.value
            sources[DJStemChoice.instrumental] = mixed
        }
        try Task.checkCancellation()
        onStatus("Saving stems")

        let folderName = "\(base) (Stems)"
        let staging = scratch.appending(path: "export", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let names = outputs.filter { sources[$0] != nil }
        func fileName(_ stem: String) -> String { "\(base) (\(stem.capitalized)).\(format.fileExtension)" }
        for (index, name) in names.enumerated() {
            let count = Double(names.count)
            var stemTags = tags.suffixingTitle(" (\(name.capitalized))", fallbackTitle: trackName)
            stemTags.comment = joined(tags.comment, "\(name.capitalized) stem · \(model.modelName)", note)
            _ = try await AudioExporter.export(
                sources[name]!, to: staging.appending(path: fileName(name)), format: format,
                tags: format.writesTags ? stemTags : nil,
                gainDB: gainDB,
                removingSource: true,
                progress: { progress(share + (1 - share) * (Double(index) + $0) / count) }
            )
        }
        try Task.checkCancellation()

        let final = outputFolder.appending(path: folderName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
        return (final, Dictionary(uniqueKeysWithValues: names.map { ($0, final.appending(path: fileName($0))) }))
    }

    /// "Repaired · −10.0 LUFS", for the comment tag; nil when nothing changed.
    static func processNote(repaired: Bool, plan: DJNormalizationPlan?) -> String? {
        var parts: [String] = []
        if repaired { parts.append("Repaired") }
        if let plan { parts.append(DJFormat.lufs(plan.resultingLUFS)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func joined(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0?.trimmed }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
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

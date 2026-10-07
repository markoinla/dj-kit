@preconcurrency import AVFoundation
import AudioExport
import Foundation

/// `DJKit <command> <files or folders…> [options]`: the app's engines without
/// the window, for scripts and agents. `DJKit -help` lists the commands.
///
/// Works on files only: never reads or writes the window's track list. Files
/// go one at a time (Apollo and the stems each peak at several GB). Each
/// file's result is one JSON line on stdout, then a summary line; progress
/// goes to stderr. Exit 0 when every file worked, 1 when any failed, 64 on
/// bad usage. Options take one dash or two (`-out`, `--out`).
@MainActor
enum Headless {
    static let helpWords: Set<String> = ["-help", "--help", "-h", "help"]

    /// A bare first word (`check`, or a typo of one) or a dashed command
    /// (`--check`). The window's own launches only pass dashed options
    /// (`-useFakeEngines YES`, `-NSDocumentRevisionsDebugMode YES`).
    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return !first.hasPrefix("-") || helpWords.contains(first) || command(first) != nil
    }

    private static func command(_ word: String) -> Command? {
        Command(rawValue: String(word.drop(while: { $0 == "-" })))
    }

    static func start(_ arguments: [String] = CommandLine.arguments) {
        let words = Array(arguments.dropFirst())
        if helpWords.contains(words[0]) {
            guard let topic = words.dropFirst().first else {
                print(overview)
                exit(0)
            }
            guard let command = command(topic) else { usage("Unknown command: \(topic)\n\n\(overview)") }
            print(command.help)
            exit(0)
        }
        guard let command = command(words[0]) else { usage("Unknown command: \(words[0])\n\n\(overview)") }
        let options: Options
        do {
            options = try Options.parse(Array(words.dropFirst()), for: command)
        } catch {
            usage("\(error.localizedDescription)\n\n\(command.help)")
        }
        if options.flags.contains("help") {
            print(command.help)
            exit(0)
        }
        Task { @MainActor in
            let ok = await Runner(command: command, options: options).run()
            exit(ok ? 0 : 1)
        }
    }

    static func usage(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(64)
    }
}

// MARK: - Commands and help

extension Headless {
    enum Command: String, CaseIterable {
        case check, tags, loudness, analyze, identify, tag, process

        /// Options that take a value.
        var valueOptions: Set<String> {
            switch self {
            case .check, .tags, .identify: []
            case .loudness: ["target", "ceiling"]
            case .analyze: ["keyTag"]
            case .tag: Set(TagField.allCases.map(\.rawValue))
            case .process: ["out", "repair", "normalize", "ceiling", "stems", "stemModel", "format", "keyTag"]
            }
        }

        /// Options that are on when present.
        var flagOptions: Set<String> {
            switch self {
            case .check, .tags, .loudness: []
            case .analyze: ["apply", "dryRun"]
            case .identify: ["apply", "applyWeak", "rename", "dryRun"]
            case .tag: ["rename", "dryRun"]
            case .process: ["noAnalyze"]
            }
        }

        /// Writes to the files themselves (so `-dryRun` means something).
        var writes: Bool { self == .tag || flagOptions.contains("apply") }

        var help: String {
            switch self {
            case .check: """
                DJKit check <files or folders…>
                  Bad-file detector: is it really lossless, where do the highs stop.
                  Read-only.
                  Out: verdict (lossless|goodLossy|lowQuality|fakeLossless|unknown), summary,
                       container, losslessContainer, bitrateKbps, sampleRate, channels,
                       duration, cutoffHz, suggestsRepair, veryLowSource
                  Example: DJKit check ~/Music/Incoming
                """
            case .tags: """
                DJKit tags <files or folders…>
                  Reads each file's tags. Read-only.
                  Out: title, artist, album, genre, year, label, isrc, comment, bpm, key,
                       artworkBytes
                  Example: DJKit tags "Artist - Title.aiff"
                """
            case .loudness: """
                DJKit loudness <files or folders…> [-target <LUFS> [-ceiling <dBTP>]]
                  Measures loudness (BS.1770-4 / EBU R128). Read-only.
                  -target   also plans the gain Normalize would apply (ceiling default -1)
                  Out: integratedLUFS, truePeakDBTP, samplePeakDBFS, loudnessRangeLU, duration,
                       plan {gainDB, limitedByCeiling, resultingLUFS, resultingTruePeakDBTP}
                  Example: DJKit loudness set/ -target -10
                """
            case .analyze: """
                DJKit analyze <files or folders…> [-apply] [-keyTag musical|camelot] [-dryRun]
                  Detects BPM and key (Beat This! + libkeyfinder). The tempo model downloads
                  on first use.
                  -apply    writes BPM / key into the file, only where it has none (the
                            file's own tags always win; an unsteady tempo isn't written)
                  -keyTag   "Am" (musical) or "8A" (camelot); default: the app's setting
                  -dryRun   with -apply: report, write nothing
                  Out: bpm, bpmSteady, rawBPM, key, keyCamelot, keyMusical, keyMargin,
                       fileBPM, fileKey, tagMismatch, toWrite {bpm, key}, written
                  Example: DJKit analyze crate/ -apply -keyTag camelot
                """
            case .identify: """
                DJKit identify <files or folders…> [-apply [-applyWeak] [-rename]] [-dryRun]
                  Track ID: Shazam, then Apple Music for album, label, year, artwork.
                  Needs the network and the signed app.
                  -apply      writes the match's tags and artwork into the file; only strong
                              matches (2+ of 3 listens agree) whose length fits the file
                  -applyWeak  with -apply: weak or length-mismatched matches too
                  -rename     with -apply: renames to "Artist - Title.ext" (" 2" when taken)
                  -dryRun     with -apply: report, write nothing
                  Out: matched, artist, title, album, label, genre, releaseDate, isrc,
                       durationSeconds, hits, listens, strong, lengthMismatch, appleMusicURL,
                       applied, path (where the file is now)
                  Example: DJKit identify unknown/ -apply -rename
                """
            case .tag: """
                DJKit tag <files…> [-title T] [-artist A] [-album A] [-genre G] [-year Y]
                                   [-label L] [-isrc I] [-comment C] [-bpm 124] [-key 8A]
                                   [-rename] [-dryRun]
                  Sets tags; fields not given stay as they are (no field can be cleared).
                  Rekordbox / Serato data and the audio stay untouched.
                  -rename   renames to "Artist - Title.ext" from the resulting tags
                  -dryRun   report, write nothing
                  Out: set {…}, path (where the file is now)
                  Example: DJKit tag "track01.mp3" -artist "Floorplan" -title "Never Grow Old"
                """
            case .process: """
                DJKit process <files or folders…> [-out <dir>] [-repair auto|on|off]
                              [-normalize <LUFS>|off] [-ceiling <dBTP>]
                              [-stems all|acapella|<names>] [-stemModel <model>]
                              [-format <format>] [-keyTag musical|camelot] [-noAnalyze]
                  The app's Process run: repair → normalize → stems, saved once as
                  "Artist - Title.<ext>" in -out. The source file is never changed.
                  -out        default: the app's output folder
                  -repair     Apollo; auto (default) repairs what the check calls lossy-sounding
                  -normalize  target LUFS, default the app's setting; off skips it
                  -ceiling    true-peak ceiling in dBTP, default the app's setting
                  -stems      all | acapella (vocals + instrumental) | comma list of
                              vocals,drums,bass,other,guitar,piano,instrumental; default none
                  -stemModel  htdemucs (default) | htdemucs_ft (cleaner, ~4× slower) |
                              htdemucs_6s (adds guitar, piano)
                  -format     aiff | wav | flac | mp3-320 | mp3-256 | mp3-192; default the
                              app's last one
                  -noAnalyze  skip BPM / key; otherwise they're detected and written into the
                              results where the file has none
                  Repair alone with nothing else on still saves a repaired copy. Apollo's
                  weights download on first use.
                  Out: output, stemsFolder, stems {name: path}, repaired, verdict,
                       normalization {gainDB, limitedByCeiling, resultingLUFS, …}, seconds
                  Example: DJKit process rips/ -normalize -9 -stems acapella -format aiff
                """
            }
        }
    }

    static var overview: String {
        """
        DJ Kit, headless. Usage: DJKit <command> <files or folders…> [options]

        Commands:
          check     bad-file detector (fake lossless, low bitrate)       read-only
          tags      read tags                                            read-only
          loudness  measure LUFS / true peak, plan normalize gain        read-only
          analyze   detect BPM and key; -apply fills missing tags        writes with -apply
          identify  Track ID (Shazam + Apple Music); -apply tags it      writes with -apply
          tag       set tags, optionally rename "Artist - Title"         writes
          process   repair → normalize → stems, saved as new files       new files only

        DJKit -help <command>   (or DJKit <command> -help) for its options and output.

        Folders are searched recursively for mp3, m4a, aac, flac, wav, aiff.
        Files go one at a time. Output, one JSON object per line on stdout:
          {"command":"check","file":"/abs/path.mp3","ok":true, …fields}
          {"command":"check","file":"/abs/bad.mp3","ok":false,"error":"…"}
          {"summary":true,"command":"check","files":2,"ok":1,"failed":1}
        Progress and status go to stderr. Exit 0: every file worked; 1: some failed;
        64: bad usage. Options take one dash or two. Write commands accept -dryRun.

        Global options: -supportDirectory <dir> (models and weights; default
        ~/Library/Application Support/DJKit), -useFakeEngines (demo engines, for testing).

        Works on files only: the app window's track list isn't touched (it shows a
        renamed file as missing). Defaults (output folder, LUFS target, key spelling,
        format) are the app's settings.
        """
    }

    enum TagField: String, CaseIterable {
        case title, artist, album, genre, year, label, isrc, comment, bpm, key

        func set(_ value: String, on tags: inout AudioTags) {
            switch self {
            case .title: tags.title = value
            case .artist: tags.artist = value
            case .album: tags.album = value
            case .genre: tags.genre = value
            case .year: tags.year = value
            case .label: tags.label = value
            case .isrc: tags.isrc = value
            case .comment: tags.comment = value
            case .bpm: tags.bpm = value
            case .key: tags.key = value
            }
        }
    }
}

// MARK: - Options

extension Headless {
    struct Options {
        var paths: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        static let globalValues: Set<String> = ["supportDirectory", "fakeEngineSpeed"]
        static let globalFlags: Set<String> = ["useFakeEngines", "help"]

        /// `-name value`, `--name value`, `--name=value`, `-flag`; anything
        /// else is a path. A value may start with a dash (`-normalize -10`).
        static func parse(_ words: [String], for command: Command) throws -> Options {
            let takesValue = command.valueOptions.union(globalValues)
            let isFlag = command.flagOptions.union(globalFlags)
            var options = Options()
            var index = 0
            while index < words.count {
                let word = words[index]
                index += 1
                guard word.hasPrefix("-"), word.count > 1, Double(word) == nil else {
                    options.paths.append(word)
                    continue
                }
                var name = String(word.drop(while: { $0 == "-" }))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if name == "h" { name = "help" }
                if takesValue.contains(name) {
                    if let inline {
                        options.values[name] = inline
                    } else if index < words.count {
                        options.values[name] = words[index]
                        index += 1
                    } else {
                        throw AppError("-\(name) needs a value.")
                    }
                } else if isFlag.contains(name), inline == nil {
                    options.flags.insert(name)
                } else {
                    throw AppError("Unknown option for \(command.rawValue): \(word)")
                }
            }
            return options
        }

        func number(_ name: String) throws -> Double? {
            guard let text = values[name] else { return nil }
            guard let value = Double(text), value.isFinite else { throw AppError("-\(name) wants a number, got \(text).") }
            return value
        }

        /// As launch arguments, for `Engines.forLaunch`.
        var engineArguments: [String] {
            var out: [String] = []
            if flags.contains("useFakeEngines") { out.append("-useFakeEngines") }
            if let speed = values["fakeEngineSpeed"] { out += ["-fakeEngineSpeed", speed] }
            return out
        }
    }
}

// MARK: - Running

extension Headless {
    @MainActor
    struct Runner {
        let command: Command
        let options: Options
        let settings = AppSettings()
        let engines: Engines
        let support: URL

        init(command: Command, options: Options) {
            self.command = command
            self.options = options
            support = options.values["supportDirectory"].map {
                URL(filePath: $0, directoryHint: .isDirectory).absoluteURL.standardizedFileURL
            } ?? AppPaths.support
            engines = Engines.forLaunch(supportDirectory: support, arguments: options.engineArguments)
        }

        func run() async -> Bool {
            if options.paths.isEmpty { Headless.usage("No files given.\n\n\(command.help)") }
            if command.writes, options.flags.contains("dryRun"), command != .tag, !options.flags.contains("apply") {
                Headless.usage("-dryRun goes with -apply.")
            }
            if command == .tag, !TagField.allCases.contains(where: { options.values[$0.rawValue] != nil }), !options.flags.contains("rename") {
                Headless.usage("Nothing to set.\n\n\(command.help)")
            }
            let plan: Any
            do {
                plan = try prepare()
            } catch {
                Headless.usage(error.localizedDescription)
            }

            var files: [URL] = []
            var missing = 0
            for path in options.paths {
                let url = URL(filePath: (path as NSString).expandingTildeInPath).absoluteURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    emit(["command": command.rawValue, "file": url.path, "ok": false, "error": "No such file or folder."])
                    missing += 1
                } else if !isDirectory.boolValue, !Track.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    emit(["command": command.rawValue, "file": url.path, "ok": false, "error": "Not a supported audio file."])
                    missing += 1
                } else {
                    files += AppModel.audioFiles(in: [url])
                }
            }
            var seen = Set<String>()
            files = files.filter { seen.insert($0.path).inserted }

            var succeeded = 0
            var failed = missing
            for (index, file) in files.enumerated() {
                let prefix = "[\(index + 1)/\(files.count)] \(file.lastPathComponent)"
                log("\(prefix)…")
                var line: [String: Any] = ["command": command.rawValue, "file": file.path]
                do {
                    let fields = try await handle(file, plan: plan, progress: ProgressLine(prefix: prefix))
                    line.merge(fields) { _, new in new }
                    line["ok"] = true
                    succeeded += 1
                } catch {
                    line["ok"] = false
                    line["error"] = error.localizedDescription
                    failed += 1
                }
                emit(line)
            }
            emit(["summary": true, "command": command.rawValue, "files": files.count + missing, "ok": succeeded, "failed": failed])
            return failed == 0
        }

        /// Checks a command's options before any file is touched.
        private func prepare() throws -> Any {
            switch command {
            case .loudness:
                guard let lufs = try options.number("target") else {
                    if options.values["ceiling"] != nil { throw AppError("-ceiling goes with -target.") }
                    return ()
                }
                return DJLoudnessTarget(lufs: lufs, ceilingDBTP: try options.number("ceiling") ?? AppSettings.defaultCeilingDBTP)
            case .analyze, .process:
                _ = try keyTag()
                return command == .process ? try processPlan() : ()
            case .check, .tags, .identify, .tag:
                return ()
            }
        }

        private func keyTag() throws -> KeyTagStyle {
            guard let text = options.values["keyTag"] else { return settings.keyTag }
            guard let style = KeyTagStyle(rawValue: text) else { throw AppError("-keyTag is musical or camelot, got \(text).") }
            return style
        }

        private func handle(_ file: URL, plan: Any, progress: ProgressLine) async throws -> [String: Any] {
            switch command {
            case .check: return try await check(file)
            case .tags: return Self.tagsJSON(await AudioTags.read(from: file))
            case .loudness: return try await loudness(file, target: plan as? DJLoudnessTarget, progress: progress)
            case .analyze: return try await analyze(file, progress: progress)
            case .identify: return try await identify(file, progress: progress)
            case .tag: return try await tag(file)
            case .process: return try await process(file, plan: plan as! ProcessPlan, progress: progress)
            }
        }

        // MARK: check, tags, loudness

        private func check(_ file: URL) async throws -> [String: Any] {
            var track = Track(url: file)
            let report = try await engines.quality.analyze(file)
            track.quality = report
            return [
                "verdict": report.verdict.rawValue, "summary": report.summary,
                "container": report.container, "losslessContainer": report.isLosslessContainer,
                "bitrateKbps": orNull(report.declaredBitrateKbps), "sampleRate": report.sampleRate,
                "channels": report.channels, "duration": round2(report.duration), "cutoffHz": orNull(report.cutoffHz.map { $0.rounded() }),
                "suggestsRepair": track.needsRepair, "veryLowSource": track.isVeryLowSource,
            ]
        }

        static func tagsJSON(_ tags: AudioTags) -> [String: Any] {
            [
                "title": orNull(tags.title), "artist": orNull(tags.artist), "album": orNull(tags.album),
                "genre": orNull(tags.genre), "year": orNull(tags.year), "label": orNull(tags.label),
                "isrc": orNull(tags.isrc), "comment": orNull(tags.comment), "bpm": orNull(tags.bpm),
                "key": orNull(tags.key), "artworkBytes": tags.artwork?.count ?? 0,
            ]
        }

        private func loudness(_ file: URL, target: DJLoudnessTarget?, progress: ProgressLine) async throws -> [String: Any] {
            let report = try await engines.loudness.measure(file) { progress.fraction($0, "measure") }
            var out: [String: Any] = [
                "integratedLUFS": round2(report.integratedLUFS), "truePeakDBTP": round2(report.truePeakDBTP),
                "samplePeakDBFS": round2(report.samplePeakDBFS), "loudnessRangeLU": orNull(report.loudnessRangeLU.map(round2)),
                "duration": round2(report.duration),
            ]
            if let target, !report.isSilent {
                out["plan"] = Self.planJSON(engines.loudness.plan(for: report, target: target))
            }
            return out
        }

        static func planJSON(_ plan: DJNormalizationPlan) -> [String: Any] {
            [
                "targetLUFS": plan.targetLUFS, "ceilingDBTP": plan.ceilingDBTP, "gainDB": round2(plan.gainDB),
                "limitedByCeiling": plan.limitedByCeiling, "resultingLUFS": round2(plan.resultingLUFS),
                "resultingTruePeakDBTP": round2(plan.resultingTruePeakDBTP),
            ]
        }

        // MARK: analyze

        /// The analysis on a `Track`, with the file's own tags beside it.
        private func analyzed(_ file: URL, progress: ProgressLine) async throws -> (track: Track, fileTags: AudioTags) {
            let analysis = try await engines.analyzer.analyze(
                file, retryingModel: false,
                progress: { progress.fraction($0, "analyze") },
                status: { progress.status($0) }
            )
            let tags = await AudioTags.read(from: file)
            var track = Track(url: file)
            track.analysis = analysis
            track.fileTags = FileMusicalTags(tags)
            return (track, tags)
        }

        private func analyze(_ file: URL, progress: ProgressLine) async throws -> [String: Any] {
            let (track, existing) = try await analyzed(file, progress: progress)
            let analysis = track.analysis!
            let filled = TrackTags.fillingAnalysis(AudioTags(), from: track, keyTag: try keyTag(), existing: existing)
            var out: [String: Any] = [
                "bpm": orNull(track.detectedBPM.map(DJBPM.string)), "bpmSteady": orNull(analysis.tempo?.isSteady),
                "rawBPM": orNull(analysis.tempo.map { round2($0.rawBPM) }),
                "key": orNull(analysis.key.map { "\($0.key.camelot) \($0.key.musical)" }),
                "keyCamelot": orNull(analysis.key?.key.camelot), "keyMusical": orNull(analysis.key?.key.musical),
                "keyMargin": orNull(analysis.key.map { round2($0.margin) }),
                "fileBPM": orNull(existing.bpm), "fileKey": orNull(existing.key),
                "tagMismatch": orNull(track.musicalTagMismatch),
                "toWrite": ["bpm": orNull(filled.bpm), "key": orNull(filled.key)] as [String: Any],
                "written": false,
            ]
            if options.flags.contains("apply"), !options.flags.contains("dryRun"), filled.bpm != nil || filled.key != nil {
                _ = try await AudioRetagger.retag(file, with: filled)
                out["written"] = true
            }
            return out
        }

        // MARK: identify, tag

        private func identify(_ file: URL, progress: ProgressLine) async throws -> [String: Any] {
            guard let identity = try await engines.identifier.identify(file, progress: { progress.fraction($0, "listen") }) else {
                return ["matched": false, "applied": false, "path": file.path]
            }
            let duration = Self.duration(of: file)
            let lengthMismatch: Bool = {
                guard let expected = identity.durationSeconds, let actual = duration, expected > 0, actual > 0 else { return false }
                return abs(expected - actual) > max(15, 0.08 * actual)
            }()
            var out: [String: Any] = [
                "matched": true, "artist": identity.artist, "title": identity.title, "album": orNull(identity.album),
                "label": orNull(identity.label), "genre": orNull(identity.genre), "releaseDate": orNull(identity.releaseDate),
                "isrc": orNull(identity.isrc), "durationSeconds": orNull(identity.durationSeconds.map(round2)),
                "hits": identity.hits, "listens": identity.listens, "strong": identity.isStrong,
                "lengthMismatch": lengthMismatch, "appleMusicURL": orNull(identity.appleMusicURL?.absoluteString),
                "applied": false, "path": file.path,
            ]
            guard options.flags.contains("apply") else { return out }
            guard (identity.isStrong && !lengthMismatch) || options.flags.contains("applyWeak") else {
                out["skipped"] = identity.isStrong ? "length doesn't fit the file (-applyWeak to apply anyway)" : "weak match (-applyWeak to apply anyway)"
                return out
            }
            let tags = await TrackTags.tags(for: identity)
            let (path, renamed) = try await write(tags, to: file)
            out["applied"] = !options.flags.contains("dryRun")
            out["path"] = path.path
            if renamed { out["renamed"] = true }
            return out
        }

        private func tag(_ file: URL) async throws -> [String: Any] {
            var tags = AudioTags()
            var set: [String: Any] = [:]
            for field in TagField.allCases {
                guard let value = options.values[field.rawValue] else { continue }
                field.set(value, on: &tags)
                set[field.rawValue] = value
            }
            let (path, renamed) = try await write(tags, to: file)
            var out: [String: Any] = ["set": set, "path": path.path, "written": !options.flags.contains("dryRun")]
            if renamed { out["renamed"] = true }
            return out
        }

        /// Merges `tags` into `file`, renamed to "Artist - Title" with
        /// `-rename`. With `-dryRun`, only where it would end up.
        private func write(_ tags: AudioTags, to file: URL) async throws -> (url: URL, renamed: Bool) {
            var destination: URL?
            if options.flags.contains("rename") {
                var merged = await AudioTags.read(from: file)
                if let title = tags.title { merged.title = title }
                if let artist = tags.artist { merged.artist = artist }
                let name = TrackTags.fileName(TrackTags.displayName(merged, fallback: file.deletingPathExtension().lastPathComponent))
                let candidate = file.deletingLastPathComponent().appending(path: "\(name).\(file.pathExtension)")
                if candidate.standardizedFileURL.path != file.standardizedFileURL.path {
                    destination = AppModel.unique(candidate)
                }
            }
            if options.flags.contains("dryRun") { return (destination ?? file, destination != nil) }
            let url = try await AudioRetagger.retag(file, with: tags, moveTo: destination)
            return (url, destination != nil)
        }

        // MARK: process

        struct ProcessPlan {
            var repair: ProcessRecipe.Repair
            var normalize: DJLoudnessTarget?
            var stems: (model: DJStemModel, choice: DJStemChoice)?
            var format: AudioFileFormat
            var output: URL
            var keyTag: KeyTagStyle
            var analyze: Bool
        }

        private func processPlan() throws -> ProcessPlan {
            let repair: ProcessRecipe.Repair = switch options.values["repair"] ?? "auto" {
            case "auto": .suggested
            case "on": .on
            case "off": .off
            case let other: throw AppError("-repair is auto, on or off, got \(other).")
            }
            let ceiling = try options.number("ceiling") ?? settings.ceilingDBTP
            let normalize: DJLoudnessTarget? = options.values["normalize"] == "off"
                ? nil : DJLoudnessTarget(lufs: try options.number("normalize") ?? settings.targetLUFS, ceilingDBTP: ceiling)

            var stems: (DJStemModel, DJStemChoice)?
            let modelName = options.values["stemModel"] ?? DJStemModel.htdemucs.modelName
            guard let model = DJStemModel.allCases.first(where: { $0.modelName == modelName || $0.rawValue == modelName }) else {
                throw AppError("-stemModel is htdemucs, htdemucs_ft or htdemucs_6s, got \(modelName).")
            }
            if let choice = options.values["stems"] {
                switch choice {
                case "all": stems = (model, .all)
                case "acapella": stems = (model, .acapellaInstrumental)
                default:
                    let names = Set(choice.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                    let known = Set(model.stemNames + [DJStemChoice.instrumental])
                    if let unknown = names.subtracting(known).first {
                        throw AppError("\(model.modelName) has no stem \"\(unknown)\"; it makes \(known.sorted().joined(separator: ", ")).")
                    }
                    stems = (model, .custom(names))
                }
            } else if options.values["stemModel"] != nil {
                throw AppError("-stemModel goes with -stems.")
            }

            let formatName = options.values["format"] ?? settings.lastRecipe.format.rawValue
            guard let format = AudioFileFormat(rawValue: formatName) else {
                throw AppError("-format is \(AudioFileFormat.allCases.map(\.rawValue).joined(separator: ", ")); got \(formatName).")
            }
            let output = options.values["out"].map {
                URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory).absoluteURL.standardizedFileURL
            } ?? settings.outputFolder
            if repair == .off, normalize == nil, stems == nil { throw AppError("Nothing to do: repair, normalize and stems are all off.") }
            return ProcessPlan(
                repair: repair, normalize: normalize, stems: stems, format: format, output: output,
                keyTag: try keyTag(), analyze: !options.flags.contains("noAnalyze") && settings.detectBPMKey
            )
        }

        private func process(_ file: URL, plan: ProcessPlan, progress: ProgressLine) async throws -> [String: Any] {
            let start = ContinuousClock.now
            var track = Track(url: file)
            if plan.repair == .suggested {
                progress.status("quality check")
                track.quality = try await engines.quality.analyze(file)
            }
            var tags = await AudioTags.read(from: file)
            if plan.analyze, !AudioTags.hasBPM(tags.bpm) || (tags.key?.trimmed.isEmpty ?? true) {
                let analysis = try await analyzed(file, progress: progress)
                track.analysis = analysis.track.analysis
                track.fileTags = analysis.track.fileTags
                tags = TrackTags.fillingAnalysis(tags, from: track, keyTag: plan.keyTag, existing: tags)
            }
            let steps = ResultWriter.Steps(
                repair: ProcessRecipe(repair: plan.repair).repairs(track), normalize: plan.normalize, stems: plan.stems
            )
            guard !steps.isEmpty else {
                return ["skipped": "nothing to do: the check found nothing to repair and the rest is off", "verdict": orNull(track.verdict?.rawValue)]
            }
            if steps.repair, await engines.apollo.state() != .ready {
                progress.status("setting up Apollo")
                try await engines.apollo.install { progress.status($0) }
            }
            try FileManager.default.createDirectory(at: plan.output, withIntermediateDirectories: true)
            let processed = try await ResultWriter.process(
                input: file, steps: steps, format: plan.format, tags: tags, outputFolder: plan.output, engines: engines,
                progress: { progress.fraction($0, "process") },
                step: { current, _ in progress.status(current.verb) },
                status: { progress.status($0) }
            )
            let files = processed.files
            let elapsed = ContinuousClock.now - start
            return [
                "output": orNull(files.output?.path), "stemsFolder": orNull(files.stemsFolder?.path),
                "stems": (files.stems ?? [:]).mapValues(\.path), "repaired": files.repaired,
                "verdict": orNull(track.verdict?.rawValue), "format": plan.format.rawValue,
                "normalization": orNull(files.normalization.map(Self.planJSON)),
                "bpm": orNull(tags.bpm), "key": orNull(tags.key),
                "seconds": round2(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18),
            ]
        }

        // MARK: Helpers

        private static func duration(of file: URL) -> TimeInterval? {
            guard let audio = try? AVAudioFile(forReading: file), audio.fileFormat.sampleRate > 0 else { return nil }
            return Double(audio.length) / audio.fileFormat.sampleRate
        }

        private func emit(_ object: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data("{\"ok\":false,\"error\":\"couldn't encode the result\"}".utf8)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

nonisolated private func log(_ line: String) {
    FileHandle.standardError.write(Data("djkit: \(line)\n".utf8))
}

nonisolated private func orNull<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

/// Two decimals; ±∞ (silence) and NaN as strings, which JSON can carry.
nonisolated private func round2(_ value: Double) -> Any {
    value.isFinite ? NSDecimalNumber(string: String(format: "%.2f", value)) : "\(value)"
}

/// One file's progress on stderr: every 10 %, and each new status line.
private final class ProgressLine: @unchecked Sendable {
    private let prefix: String
    private let lock = NSLock()
    private var logged: [String: Double] = [:]
    private var lastStatus: String?

    init(prefix: String) { self.prefix = prefix }

    func fraction(_ value: Double, _ label: String) {
        let show: Bool = lock.withLock {
            let last = logged[label] ?? -1
            guard value - last >= 0.1 || (value >= 1 && last < 1) else { return false }
            logged[label] = value
            return true
        }
        if show { log("\(prefix): \(label) \(Int((value * 100).rounded()))%") }
    }

    func status(_ text: String) {
        let show: Bool = lock.withLock {
            guard text != lastStatus else { return false }
            lastStatus = text
            return true
        }
        if show { log("\(prefix): \(text)") }
    }
}

import AVFoundation
import AudioExport
import Foundation

/// `DJKit -selfTest <audio file> <output dir> [-selfTestApollo] [-selfTestNormalize] [-selfTestFormat <format>] [-supportDirectory <dir>]`
///
/// Runs the app's own engine adapters (the same `Engines` the window uses,
/// not the packages directly) on one file, headless, then prints one JSON
/// object to stdout and exits: 0 when every step passed, 1 otherwise.
/// Progress goes to stderr. Steps run one after another (Apollo and the
/// stems each peak at several GB, never together):
///
/// 1. quality check;
/// 1b. with `-selfTestIdentify`: Track ID (Shazam + Apple Music; needs the
///    team-signed build);
/// 1c. with `-selfTestAnalyze`: BPM and key (the tempo model downloaded
///    first if needed), then the Apply rule on a copy of the input
///    (`<out>/apply-check.<ext>`, retagged in place): BPM and key land only
///    where the file had none. The Process run's outputs must then carry the
///    file's own BPM / key, else the detected ones (`-selfTestKeyTag camelot`
///    spells the key 8A; default musical);
/// 2. one Process run, as the app does it (`ResultWriter.process`): with
///    `-selfTestApollo` a repair (Apollo installed first if needed), with
///    `-selfTestNormalize` normalizing to `-selfTestTarget` LUFS (default
///    −10) under a `-selfTestCeiling` dBTP ceiling (default −1), then stems
///    with htdemucs (skip with `-selfTestSkipStems`; `-selfTestAcapella`
///    keeps only vocals and the instrumental). The finished track is
///    measured again with LoudnessKit and must land within ±0.2 LU of the
///    target, or, when the plan was capped, on the ceiling (±0.1 dB; lossy
///    output only has to stay within 0.5 dB of it).
/// 3. with `-selfTestAdd normalize|stems` (a step 2 skipped): Run on that
///    step, as the done card does it (`ResultWriter.add`). Normalize: the
///    finished track must land on the target as in 2, and each stem's sample
///    peak move by the same gain (±0.2 dB; lossy ±0.5). Stems: checked as in
///    2, the finished track left as it was.
///
/// Everything is saved as `-selfTestFormat` (aiff, wav, flac, mp3-320,
/// mp3-256, mp3-192; default aiff); each output is decoded again and its
/// rate, channels, length and tags reported (the finished track's title
/// must be the source's, unsuffixed).
///
/// Point `-supportDirectory` somewhere disposable to keep models and the
/// Apollo weights out of `~/Library/Application Support/DJKit`.
/// `-useFakeEngines` runs the same steps on the fakes.
/// Available in Release too: there's no GUI session on the build Mac.
@MainActor
enum SelfTest {
    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("-selfTest")
    }

    static func start(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "-selfTest"), arguments.indices.contains(index + 2) else {
            FileHandle.standardError.write(Data("usage: DJKit -selfTest <audio file> <output dir> [-selfTestApollo] [-selfTestNormalize [-selfTestTarget -10] [-selfTestCeiling -1]] [-selfTestSkipStems] [-selfTestFormat aiff|wav|flac|mp3-320|mp3-256|mp3-192] [-supportDirectory <dir>]\n".utf8))
            exit(64)
        }
        let input = absolute(arguments[index + 1], directory: false)
        let output = absolute(arguments[index + 2], directory: true)
        Task { @MainActor in
            let ok = await run(input: input, output: output, arguments: arguments)
            exit(ok ? 0 : 1)
        }
    }

    private static func absolute(_ path: String, directory: Bool) -> URL {
        URL(filePath: path, directoryHint: directory ? .isDirectory : .notDirectory).absoluteURL.standardizedFileURL
    }

    nonisolated private static func log(_ line: String) {
        FileHandle.standardError.write(Data("selfTest: \(line)\n".utf8))
    }

    private static func run(input originalInput: URL, output: URL, arguments: [String]) async -> Bool {
        var input = originalInput
        let support = AppPaths.support
        let engines = Engines.forLaunch(supportDirectory: support, arguments: arguments)
        let withApollo = LaunchArguments.flag("selfTestApollo", in: arguments) == true
        let skipStems = LaunchArguments.flag("selfTestSkipStems", in: arguments) == true
        let withNormalize = LaunchArguments.flag("selfTestNormalize", in: arguments) == true
        let target = DJLoudnessTarget(
            lufs: LaunchArguments.value("selfTestTarget", in: arguments).flatMap(Double.init) ?? AppSettings.defaultTargetLUFS,
            ceilingDBTP: LaunchArguments.value("selfTestCeiling", in: arguments).flatMap(Double.init) ?? AppSettings.defaultCeilingDBTP
        )
        let formatName = LaunchArguments.value("selfTestFormat", in: arguments) ?? AudioFileFormat.aiff.rawValue
        guard let format = AudioFileFormat(rawValue: formatName) else {
            emit(["ok": false, "error": "Unknown -selfTestFormat \(formatName)"])
            return false
        }
        var result: [String: Any] = [
            "input": input.path,
            "outputDirectory": output.path,
            "supportDirectory": support.path,
            "engines": engines.isFake ? "fake" : "real",
            "format": format.rawValue,
            "apolloModels": support.appending(path: "models/apollo-mlx").path,
            "bundlesPythonApollo": Bundle.main.url(forResource: "apollo", withExtension: nil) != nil,
            "physicalMemoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        ]
        var ok = true
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double {
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            return (s * 1000).rounded() / 1000
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            result["error"] = "Can't create the output folder: \(error.localizedDescription)"
            emit(result)
            return false
        }

        // 1. Quality.
        log("quality check…")
        var track = Track(url: input)
        do {
            let start = clock.now
            let report = try await engines.quality.analyze(input)
            let elapsed = clock.now - start
            track.quality = report
            result["quality"] = [
                "ok": true, "seconds": seconds(elapsed),
                "verdict": report.verdict.rawValue, "summary": report.summary,
                "container": report.container, "isLosslessContainer": report.isLosslessContainer,
                "declaredBitrateKbps": orNull(report.declaredBitrateKbps),
                "sampleRate": report.sampleRate, "channels": report.channels,
                "duration": report.duration, "cutoffHz": orNull(report.cutoffHz),
                "suggestsRepair": track.needsRepair,
                "showsLowSourceNote": track.isVeryLowSource,
            ] as [String: Any]
            log("quality: \(report.verdict.rawValue) — \(report.summary)")
        } catch {
            ok = false
            result["quality"] = ["ok": false, "error": error.localizedDescription]
        }

        // 1b. Track ID (Shazam + Apple Music), with -selfTestIdentify.
        if LaunchArguments.flag("selfTestIdentify", in: arguments) == true {
            log("track ID…")
            do {
                let start = clock.now
                let identity = try await engines.identifier.identify(input, progress: { _ in })
                let elapsed = clock.now - start
                if let identity {
                    log("track ID: \(identity.artist) - \(identity.title) (\(identity.hits)/\(identity.listens))")
                    // -selfTestApply: write the match into the input and rename it, as Apply does.
                    if LaunchArguments.flag("selfTestApply", in: arguments) == true {
                        let tags = await TrackTags.tags(for: identity)
                        let name = TrackTags.fileName(TrackTags.displayName(tags, fallback: input.deletingPathExtension().lastPathComponent))
                        let destination = AppModel.unique(input.deletingLastPathComponent().appending(path: "\(name).\(input.pathExtension)"))
                        input = try await AudioRetagger.retag(input, with: tags, moveTo: destination)
                        let back = await AudioTags.read(from: input)
                        log("applied: \(input.lastPathComponent) · \(back.artist ?? "-") / \(back.title ?? "-") / \(back.album ?? "-") / \(back.label ?? "-") / \(back.year ?? "-") / artwork \(back.artwork?.count ?? 0) bytes")
                        result["applied"] = input.path
                    }
                    result["trackID"] = [
                        "ok": true, "seconds": seconds(elapsed), "matched": true,
                        "artist": identity.artist, "title": identity.title, "album": orNull(identity.album),
                        "label": orNull(identity.label), "genre": orNull(identity.genre),
                        "releaseDate": orNull(identity.releaseDate), "isrc": orNull(identity.isrc),
                        "durationSeconds": orNull(identity.durationSeconds),
                        "artworkURL": orNull(identity.artworkURL?.absoluteString),
                        "hits": identity.hits, "listens": identity.listens,
                    ] as [String: Any]
                } else {
                    log("track ID: no match")
                    result["trackID"] = ["ok": true, "seconds": seconds(elapsed), "matched": false] as [String: Any]
                }
            } catch {
                ok = false
                result["trackID"] = ["ok": false, "error": error.localizedDescription]
            }
        }

        // 1c. BPM and key, with -selfTestAnalyze.
        let keyTag = LaunchArguments.value("selfTestKeyTag", in: arguments).flatMap(KeyTagStyle.init) ?? .musical
        var expectedMusical: (bpm: String?, key: String?)?
        if LaunchArguments.flag("selfTestAnalyze", in: arguments) == true {
            log("BPM and key…")
            let status = CallbackRecorder<String>()
            let progress = CallbackRecorder<Double>()
            do {
                let start = clock.now
                let analysis = try await engines.analyzer.analyze(
                    input, retryingModel: false,
                    progress: { progress.record($0, every: 0.25) { log("analyze \(Int($0 * 100))%") } },
                    status: { status.record($0, every: 0) { log("analyze status: \($0)") } }
                )
                let elapsed = clock.now - start
                let source = await AudioTags.read(from: input)
                track.analysis = analysis
                track.fileTags = FileMusicalTags(source)
                let filled = TrackTags.fillingAnalysis(source, from: track, keyTag: keyTag, existing: source)
                expectedMusical = (filled.bpm, filled.key)
                log("analyze: \(track.musicalReadout ?? "nothing found")\(track.musicalTagMismatch.map { " (\($0))" } ?? "")")

                // Apply's rule, on a copy: only where the file has none.
                let copy = output.appending(path: "apply-check.\(input.pathExtension)")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: input, to: copy)
                let applied = TrackTags.fillingAnalysis(AudioTags(), from: track, keyTag: keyTag, existing: source)
                _ = try await AudioRetagger.retag(copy, with: applied)
                let back = await AudioTags.read(from: copy)
                let applyOK = back.bpm == filled.bpm && back.key == filled.key
                result["analyze"] = [
                    "ok": applyOK, "seconds": seconds(elapsed),
                    "rawBPM": orNull(analysis.tempo?.rawBPM), "stability": orNull(analysis.tempo?.stability),
                    "isSteady": orNull(analysis.tempo?.isSteady), "beatCount": orNull(analysis.tempo?.beatCount),
                    "key": orNull(analysis.key.map { "\($0.key.camelot) \($0.key.musical)" }),
                    "keyMargin": orNull(analysis.key?.margin), "duration": analysis.duration,
                    "readout": orNull(track.musicalReadout), "tagMismatch": orNull(track.musicalTagMismatch),
                    "sourceBPM": orNull(source.bpm), "sourceKey": orNull(source.key), "sourceGenre": orNull(source.genre),
                    "expectedBPM": orNull(filled.bpm), "expectedKey": orNull(filled.key),
                    "applyCheck": ["path": copy.path, "bpm": orNull(back.bpm), "key": orNull(back.key)] as [String: Any],
                    "progress": progress.summary, "status": status.summary,
                ] as [String: Any]
                ok = ok && applyOK
            } catch {
                ok = false
                result["analyze"] = ["ok": false, "error": error.localizedDescription]
            }
        }

        // 2. Process: repair → normalize → stems in one run, as the app does.
        let steps = ResultWriter.Steps(
            repair: withApollo,
            normalize: withNormalize ? target : nil,
            stems: skipStems ? nil : (.htdemucs, LaunchArguments.flag("selfTestAcapella", in: arguments) == true ? .acapellaInstrumental : .all)
        )
        var firstRun: ProcessedFiles?
        if !steps.isEmpty {
            var step: [String: Any] = [
                "repair": steps.repair, "normalize": withNormalize, "stems": !skipStems,
            ]
            do {
                if steps.repair, await engines.apollo.state() != .ready {
                    log("Apollo install…")
                    let lines = CallbackRecorder<String>()
                    let start = clock.now
                    try await engines.apollo.install { line in
                        lines.record(line, every: 0) { log("install: \($0)") }
                    }
                    step["installSeconds"] = seconds(clock.now - start)
                    step["installStatus"] = lines.summary
                }
                log("process (\(format.rawValue))…")
                let progress = CallbackRecorder<Double>()
                let status = CallbackRecorder<String>()
                let stepChanges = CallbackRecorder<String>()
                let stepOrder = StepOrder()
                let start = clock.now
                var tags = await AudioTags.read(from: input)
                tags = TrackTags.fillingAnalysis(tags, from: track, keyTag: keyTag, existing: tags)
                let processed = try await ResultWriter.process(
                    input: input, steps: steps, format: format, tags: tags, outputFolder: output, engines: engines,
                    progress: { progress.record($0, every: 0.1) { log("process \(Int($0 * 100))%") } },
                    step: { current, _ in
                        if stepOrder.enter(current) { stepChanges.record(current.rawValue, every: 0) { log("process step: \($0)") } }
                    },
                    status: { status.record($0, every: 0) { log("process status: \($0)") } }
                )
                let elapsed = clock.now - start
                let files = processed.files
                firstRun = files
                let duration = engines.isFake ? nil : track.quality?.duration
                var stepOK = true

                if let written = files.output {
                    // No suffix: the finished track keeps the source's title.
                    let check = await checkOutput(written, format: format, expectedDuration: duration, expectedTitle: tags.title ?? input.deletingPathExtension().lastPathComponent,
                                                  expectedMusical: expectedMusical)
                    step["track"] = check.json
                    stepOK = stepOK && check.ok
                    if let plan = files.normalization, let measured = processed.loudness {
                        let landed = await verifyNormalized(written, plan: plan, source: measured, format: format, engines: engines)
                        step["loudness"] = landed.json
                        stepOK = stepOK && landed.ok
                    }
                } else if steps.writesTrack {
                    stepOK = false
                    step["error"] = "no finished track"
                }

                if let stemsStep = steps.stems {
                    var stemFiles: [String: Any] = [:]
                    for (name, url) in files.stems ?? [:] {
                        let check = await checkOutput(url, format: format, expectedDuration: duration,
                                                      expectedTitleSuffix: " (\(name.capitalized))", expectedMusical: expectedMusical)
                        stemFiles[name] = check.json
                        stepOK = stepOK && check.ok
                    }
                    step["stemFiles"] = stemFiles
                    stepOK = stepOK && Set((files.stems ?? [:]).keys) == Set(stemsStep.choice.outputs(for: stemsStep.model))
                }
                let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: output.path))?
                    .filter { $0.hasPrefix(".") || $0.hasSuffix(".wav") && format != .wav && $0 != "apply-check.wav" } ?? []
                stepOK = stepOK && leftovers.isEmpty
                // Every step the run does, once each, in order.
                stepOK = stepOK && stepOrder.entered == steps.order && !stepOrder.wentBack
                step["leftovers"] = leftovers
                step["ok"] = stepOK
                step["seconds"] = seconds(elapsed)
                step["realtimeFactor"] = orNull(track.quality.map { $0.duration / max(seconds(elapsed), 0.001) })
                step["output"] = orNull(files.output?.path)
                step["stemsFolder"] = orNull(files.stemsFolder?.path)
                step["progress"] = progress.summary
                step["status"] = status.summary
                step["steps"] = stepChanges.summary
                step["processPeakRSSMB"] = peakRSSMB(children: false)
                ok = ok && stepOK
                log("process done in \(seconds(elapsed)) s")
            } catch {
                ok = false
                step["ok"] = false
                step["error"] = error.localizedDescription
            }
            result["process"] = step
        }

        // 3. Run on a skipped step, keeping what the run saved.
        if let added = LaunchArguments.value("selfTestAdd", in: arguments).flatMap(ProcessStep.init(rawValue:)),
           added != .repair, let previous = firstRun, !previous.did(added) {
            var step: [String: Any] = ["step": added.rawValue]
            do {
                log("add \(added.rawValue)…")
                var before: [String: DJLoudnessReport] = [:]
                for (name, url) in previous.stems ?? [:] {
                    before[name] = try await engines.loudness.measure(url, progress: { _ in })
                }
                let stepOrder = StepOrder()
                var tags = await AudioTags.read(from: input)
                tags = TrackTags.fillingAnalysis(tags, from: track, keyTag: keyTag, existing: tags)
                let run = try await ResultWriter.add(
                    added, to: previous, target: target, stems: (.htdemucs, .all),
                    input: input, format: format, tags: tags, outputFolder: output, engines: engines,
                    progress: { _ in }, step: { current, _ in _ = stepOrder.enter(current) }, status: { log("add status: \($0)") }
                )
                let files = run.files
                var stepOK = stepOrder.entered == [added] && files.repaired == previous.repaired
                if added == .stems {
                    // The finished track stays; the stems come from the same audio at its level.
                    stepOK = stepOK && files.output == previous.output && files.normalization == previous.normalization
                    let duration = engines.isFake ? nil : track.quality?.duration
                    var stemFiles: [String: Any] = [:]
                    for (name, url) in files.stems ?? [:] {
                        let check = await checkOutput(url, format: format, expectedDuration: duration,
                                                      expectedTitleSuffix: " (\(name.capitalized))", expectedMusical: expectedMusical)
                        stemFiles[name] = check.json
                        stepOK = stepOK && check.ok
                    }
                    step["stemFiles"] = stemFiles
                    stepOK = stepOK && Set((files.stems ?? [:]).keys) == Set(DJStemChoice.all.outputs(for: .htdemucs))
                } else if let written = files.output, let plan = files.normalization {
                    stepOK = stepOK && files.stems == previous.stems
                    let source = try await engines.loudness.measure(previous.repaired ? previous.output! : input, progress: { _ in })
                    let landed = await verifyNormalized(written, plan: plan, source: source, format: format, engines: engines)
                    step["loudness"] = landed.json
                    stepOK = stepOK && landed.ok
                    if !engines.isFake {
                        var stems: [String: Any] = [:]
                        for (name, url) in files.stems ?? [:] {
                            // Sample peaks: a quiet stem's loudness moves through the
                            // −70 LUFS gate, its peak moves by exactly the gain.
                            guard let was = before[name], was.samplePeakDBFS.isFinite else { continue }
                            let now = try await engines.loudness.measure(url, progress: { _ in })
                            let error = (now.samplePeakDBFS - was.samplePeakDBFS) - plan.gainDB
                            stems[name] = round2(error)
                            stepOK = stepOK && abs(error) <= (format.isLossless ? 0.2 : 0.5)
                        }
                        step["stemGainError"] = stems
                    }
                } else {
                    stepOK = false
                    step["error"] = "no normalized track"
                }
                step["output"] = orNull(files.output?.path)
                step["ok"] = stepOK
                ok = ok && stepOK
            } catch {
                ok = false
                step["ok"] = false
                step["error"] = error.localizedDescription
            }
            result["add"] = step
        }

        result["ok"] = ok
        emit(result)
        return ok
    }

    /// Measures a normalized file again: it must sit at the target (±0.2 LU),
    /// or, when the plan was capped, have its true peak on the ceiling (±0.1
    /// dB lossless; lossy output only within 0.5 dB, the encoder moves peaks).
    /// The fakes' measurements are made up, so for them only the plan is reported.
    private static func verifyNormalized(_ url: URL, plan: DJNormalizationPlan, source: DJLoudnessReport,
                                         format: AudioFileFormat, engines: Engines) async -> (ok: Bool, json: [String: Any]) {
        var json: [String: Any] = [
            "source": loudnessJSON(source),
            "plan": [
                "targetLUFS": plan.targetLUFS, "ceilingDBTP": plan.ceilingDBTP, "gainDB": round2(plan.gainDB),
                "limitedByCeiling": plan.limitedByCeiling, "resultingLUFS": round2(plan.resultingLUFS),
                "resultingTruePeakDBTP": round2(plan.resultingTruePeakDBTP),
            ] as [String: Any],
        ]
        guard !engines.isFake else { return (true, json) }
        do {
            let after = try await engines.loudness.measure(url, progress: { _ in })
            json["remeasured"] = loudnessJSON(after)
            let lufsError = after.integratedLUFS - (plan.limitedByCeiling ? plan.resultingLUFS : plan.targetLUFS)
            let peakError = after.truePeakDBTP - plan.ceilingDBTP
            json["lufsError"] = round2(lufsError)
            json["peakVsCeiling"] = round2(peakError)
            var ok = abs(lufsError) <= 0.2
            if plan.limitedByCeiling {
                ok = ok && (format.isLossless ? abs(peakError) <= 0.1 : abs(peakError) <= 0.5)
            } else if format.isLossless {
                ok = ok && peakError <= 0.1
            }
            json["ok"] = ok
            return (ok, json)
        } catch {
            json["error"] = error.localizedDescription
            return (false, json)
        }
    }

    private static func loudnessJSON(_ r: DJLoudnessReport) -> [String: Any] {
        [
            "integratedLUFS": round2(r.integratedLUFS), "truePeakDBTP": round2(r.truePeakDBTP),
            "samplePeakDBFS": round2(r.samplePeakDBFS), "loudnessRangeLU": r.loudnessRangeLU.map(round2) ?? NSNull(),
            "sampleRate": r.sampleRate, "duration": round2(r.duration),
        ]
    }

    private static func round2(_ value: Double) -> Any {
        value.isFinite ? NSDecimalNumber(string: String(format: "%.2f", value)) : "\(value)"
    }

    /// Decodes a saved result again: right extension, decodable, 44.1 kHz for
    /// MP3, the source's length (± one MP3 frame; skipped for the fakes'
    /// one-second files), and the suffixed title where the format has tags.
    private static func checkOutput(_ url: URL, format: AudioFileFormat, expectedDuration: TimeInterval?,
                                    expectedTitleSuffix: String = "", expectedTitle: String? = nil,
                                    expectedMusical: (bpm: String?, key: String?)? = nil) async -> (ok: Bool, json: [String: Any]) {
        var json: [String: Any] = ["path": url.path, "bytes": orNull(fileSize(url))]
        guard url.pathExtension == format.fileExtension else {
            json["error"] = "extension \(url.pathExtension), expected \(format.fileExtension)"
            return (false, json)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            json["error"] = "doesn't decode: \(error.localizedDescription)"
            return (false, json)
        }
        let rate = file.fileFormat.sampleRate
        let duration = Double(file.length) / rate
        json["sampleRate"] = rate
        json["channels"] = Int(file.fileFormat.channelCount)
        json["duration"] = (duration * 1000).rounded() / 1000
        var ok = file.length > 0
        if !format.isLossless, rate != 44_100 { ok = false }
        if let expectedDuration, abs(duration - expectedDuration) > 1_152.0 / 44_100 + 0.01 {
            json["durationError"] = "expected \(expectedDuration) s"
            ok = false
        }
        if format.writesTags {
            if format == .flac {
                // AVFoundation doesn't read Vorbis comments; look for the field itself.
                let data = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
                let found = data.prefix(4 << 20).range(of: Data("TITLE=".utf8)) != nil
                json["tagged"] = found
                ok = ok && found
            } else {
                let tags = await AudioTags.read(from: url)
                json["title"] = orNull(tags.title)
                json["artist"] = orNull(tags.artist)
                json["album"] = orNull(tags.album)
                json["artworkBytes"] = tags.artwork?.count ?? 0
                ok = ok && (tags.title?.hasSuffix(expectedTitleSuffix) ?? false)
                if let expectedTitle { ok = ok && tags.title == expectedTitle }
                json["comment"] = orNull(tags.comment)
                json["bpm"] = orNull(tags.bpm)
                json["key"] = orNull(tags.key)
                if let expectedMusical { ok = ok && tags.bpm == expectedMusical.bpm && tags.key == expectedMusical.key }
            }
        }
        json["ok"] = ok
        return (ok, json)
    }

    private static func describe(_ state: DJApolloSetupState) -> String {
        switch state {
        case .notInstalled: "notInstalled"
        case .installing(let line): "installing: \(line)"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func orNull<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// ru_maxrss is in bytes on macOS.
    private static func peakRSSMB(children: Bool) -> Int {
        var usage = rusage()
        getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss / 1_048_576)
    }

    private static func emit(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"couldn't encode results\"}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// The steps a run reported, in the order it entered them.
private final class StepOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ProcessStep] = []
    private var back = false

    /// Notes `step`; true when it's a new one.
    func enter(_ step: ProcessStep) -> Bool {
        lock.withLock {
            if steps.last == step { return false }
            if steps.contains(step) { back = true; return false }
            steps.append(step)
            return true
        }
    }

    var entered: [ProcessStep] { lock.withLock { steps } }
    var wentBack: Bool { lock.withLock { back } }
}

/// Collects engine callbacks: how many, whether each arrived on the main
/// thread (the adapters promise that), and for numbers whether they only
/// went forward.
private final class CallbackRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var offMain = 0
    private var values: [Value] = []
    private var lastLogged: Double = -1
    private var backwards = 0
    private var last: Double?

    func record(_ value: Value, every step: Double, log: (Value) -> Void) {
        let isMain = Thread.isMainThread
        let shouldLog: Bool = lock.withLock {
            count += 1
            if !isMain { offMain += 1 }
            if let number = value as? Double {
                if let last, number < last { backwards += 1 }
                last = number
                if number - lastLogged >= step || number == 1 { lastLogged = number; return true }
                return false
            }
            values.append(value)
            return true
        }
        if shouldLog { log(value) }
    }

    var summary: [String: Any] {
        lock.withLock {
            var out: [String: Any] = ["callbacks": count, "offMainThread": offMain]
            if let last { out["last"] = last; out["wentBackwards"] = backwards }
            if !values.isEmpty { out["lines"] = values.map { "\($0)" } }
            return out
        }
    }
}

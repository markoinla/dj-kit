import AVFoundation
import AudioExport
import Foundation

/// `DJTools -selfTest <audio file> <output dir> [-selfTestApollo] [-selfTestFormat <format>] [-supportDirectory <dir>]`
///
/// Runs the app's own engine adapters (the same `Engines` the window uses,
/// not the packages directly) on one file, headless, then prints one JSON
/// object to stdout and exits: 0 when every step passed, 1 otherwise.
/// Progress goes to stderr. Steps run one after another (stems and Apollo
/// each peak around 6 GB, never together):
///
/// 1. quality check;
/// 2. stems with htdemucs (skip with `-selfTestSkipStems`);
/// 3. with `-selfTestApollo`: Apollo install if needed, then a repair.
///
/// Stems and the repair are saved the way the app saves them
/// (`ResultWriter`), as `-selfTestFormat` (aiff, wav, flac, mp3-320,
/// mp3-256, mp3-192; default aiff); each output is decoded again and its
/// rate, channels, length and tags reported.
///
/// Point `-supportDirectory` somewhere disposable to keep models and the
/// Apollo runtime out of `~/Library/Application Support/DJTools`.
/// `-useFakeEngines` runs the same steps on the fakes.
/// Available in Release too: there's no GUI session on the build Mac.
@MainActor
enum SelfTest {
    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("-selfTest")
    }

    static func start(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "-selfTest"), arguments.indices.contains(index + 2) else {
            FileHandle.standardError.write(Data("usage: DJTools -selfTest <audio file> <output dir> [-selfTestApollo] [-selfTestFormat aiff|wav|flac|mp3-320|mp3-256|mp3-192] [-supportDirectory <dir>]\n".utf8))
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

    private static func run(input: URL, output: URL, arguments: [String]) async -> Bool {
        let support = AppPaths.support
        let engines = Engines.forLaunch(supportDirectory: support, arguments: arguments)
        let withApollo = LaunchArguments.flag("selfTestApollo", in: arguments) == true
        let skipStems = LaunchArguments.flag("selfTestSkipStems", in: arguments) == true
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
            "apolloProject": orNull(Bundle.main.url(forResource: "apollo", withExtension: nil)?.path),
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

        // 2. Stems.
        if !skipStems {
            log("stems (htdemucs, \(format.rawValue))…")
            let recorder = CallbackRecorder<Double>()
            let statusLines = CallbackRecorder<String>()
            do {
                let start = clock.now
                let stems = try await ResultWriter.separate(
                    input: input, model: .htdemucs, format: format, outputFolder: output, engine: engines.stems,
                    progress: { recorder.record($0, every: 0.1) { log("stems \(Int($0 * 100))%") } },
                    status: { statusLines.record($0, every: 0) { log("stems status: \($0)") } }
                )
                let elapsed = clock.now - start
                var files: [String: Any] = [:]
                var outputsOK = true
                for (name, url) in stems.stems {
                    let check = await checkOutput(url, format: format, expectedDuration: engines.isFake ? nil : track.quality?.duration,
                                                  expectedTitleSuffix: " (\(name.capitalized))")
                    files[name] = check.json
                    outputsOK = outputsOK && check.ok
                }
                let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: output.path))?
                    .filter { $0.hasPrefix(".") || $0.hasSuffix(".wav") && format != .wav } ?? []
                let stepOK = outputsOK && leftovers.isEmpty && Set(stems.stems.keys) == Set(DJStemModel.htdemucs.stemNames)
                ok = ok && stepOK
                result["stems"] = [
                    "ok": stepOK, "model": DJStemModel.htdemucs.modelName, "seconds": seconds(elapsed),
                    "realtimeFactor": orNull(track.quality.map { $0.duration / max(seconds(elapsed), 0.001) }),
                    "stems": files,
                    "leftovers": leftovers,
                    "progress": recorder.summary,
                    "status": statusLines.summary,
                    "processPeakRSSMB": peakRSSMB(children: false),
                ] as [String: Any]
                log("stems done in \(seconds(elapsed)) s")
            } catch {
                ok = false
                result["stems"] = ["ok": false, "error": error.localizedDescription, "progress": recorder.summary]
            }
        }

        // 3. Apollo.
        if withApollo {
            var apollo: [String: Any] = ["initialState": describe(await engines.apollo.state())]
            do {
                if await engines.apollo.state() != .ready {
                    log("Apollo install…")
                    let lines = CallbackRecorder<String>()
                    let start = clock.now
                    try await engines.apollo.install { line in
                        lines.record(line, every: 0) { log("install: \($0)") }
                    }
                    let elapsed = clock.now - start
                    apollo["installSeconds"] = seconds(elapsed)
                    apollo["installStatus"] = lines.summary
                }
                apollo["stateAfterInstall"] = describe(await engines.apollo.state())

                log("Apollo repair…")
                let progress = CallbackRecorder<Double>()
                let status = CallbackRecorder<String>()
                let start = clock.now
                let written = try await ResultWriter.repair(
                    input: input, format: format, outputFolder: output, engine: engines.apollo,
                    progress: { progress.record($0, every: 0.1) { log("repair \(Int($0 * 100))%") } },
                    status: { status.record($0, every: 0) { log("repair status: \($0)") } }
                )
                let elapsed = clock.now - start
                let check = await checkOutput(written, format: format, expectedDuration: engines.isFake ? nil : track.quality?.duration,
                                              expectedTitleSuffix: " (Repaired)")
                apollo["check"] = check.json
                let stepOK = check.ok
                ok = ok && stepOK
                apollo["ok"] = stepOK
                apollo["repairSeconds"] = seconds(elapsed)
                apollo["realtimeFactor"] = orNull(track.quality.map { $0.duration / max(seconds(elapsed), 0.001) })
                apollo["output"] = written.path
                apollo["outputBytes"] = orNull(fileSize(written))
                apollo["progress"] = progress.summary
                apollo["status"] = status.summary
                apollo["childPeakRSSMB"] = peakRSSMB(children: true)
                log("repair done in \(seconds(elapsed)) s")
            } catch {
                ok = false
                apollo["ok"] = false
                apollo["error"] = error.localizedDescription
            }
            result["apollo"] = apollo
        }

        result["ok"] = ok
        emit(result)
        return ok
    }

    /// Decodes a saved result again: right extension, decodable, 44.1 kHz for
    /// MP3, the source's length (± one MP3 frame; skipped for the fakes'
    /// one-second files), and the suffixed title where the format has tags.
    private static func checkOutput(_ url: URL, format: AudioFileFormat, expectedDuration: TimeInterval?,
                                    expectedTitleSuffix: String) async -> (ok: Bool, json: [String: Any]) {
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

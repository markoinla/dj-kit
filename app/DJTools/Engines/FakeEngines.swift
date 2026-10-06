import Foundation

// Stand-ins for the engine packages, so the app runs end to end before they
// exist: they sleep, report progress and write placeholder files (short
// silent WAVs) where the real ones would. Picked with `-useFakeEngines`, or
// whenever the real engines aren't linked (`Engines.forLaunch`).
// `-fakeEngineSpeed 4` makes them four times quicker.

/// A deterministic verdict per file name, so a list looks the same on every
/// run: lossless containers are mostly Lossless, sometimes Fake lossless;
/// lossy ones Good or Low quality. A name with "128" is Low quality, one
/// with "fake" is Fake lossless.
struct FakeQualityChecker: QualityChecking {
    var speed: Double = 1

    func analyze(_ url: URL) async throws -> DJQualityReport {
        let hash = FakeHash.of(url.lastPathComponent)
        try await Task.sleep(for: .milliseconds(Int(Double(400 + Int(hash % 900)) / speed)))
        return Self.report(for: url)
    }

    static func report(for url: URL) -> DJQualityReport {
        let name = url.lastPathComponent.lowercased()
        let container = url.pathExtension.lowercased()
        let hash = FakeHash.of(url.lastPathComponent)
        let lossless = ["flac", "wav", "aiff", "aif"].contains(container)
        let duration = 200 + Double(hash % 260)
        var report = DJQualityReport(
            url: url, container: container, isLosslessContainer: lossless,
            declaredBitrateKbps: nil, sampleRate: 44_100, channels: 2, duration: duration,
            cutoffHz: nil, verdict: .unknown, summary: ""
        )
        if lossless {
            if container == "flac" { report.declaredBitrateKbps = 900 + Int(hash % 200) }
            if container == "wav" || container.hasPrefix("aif") { report.declaredBitrateKbps = 1411 }
            if name.contains("fake") || hash % 4 == 0 {
                report.cutoffHz = 16_000
                report.verdict = .fakeLossless
                report.summary = "Cuts off at 16 kHz — a lossy file saved as \(container.uppercased())"
            } else {
                report.cutoffHz = 21_800 + Double(hash % 250)
                report.verdict = .lossless
                report.summary = "Full range up to 22 kHz — genuinely lossless"
            }
        } else if name.contains("128") || hash % 3 == 0 {
            report.declaredBitrateKbps = 128
            report.cutoffHz = 16_000
            report.verdict = .lowQuality
            report.summary = "Cuts off at 16 kHz — likely a 128 kbps \(container == "mp3" ? "MP3" : "file")"
        } else {
            report.declaredBitrateKbps = container == "mp3" ? 320 : 256
            report.cutoffHz = container == "mp3" ? 20_000 : 19_500
            report.verdict = .goodLossy
            report.summary = "Cuts off at \(String(format: "%g", (report.cutoffHz ?? 0) / 1000)) kHz — a good \(report.declaredBitrateKbps ?? 0) kbps encode"
        }
        return report
    }
}

/// Counts up for a few seconds per track, then writes a silent WAV per stem
/// into `<outputDirectory>/<track name> (Stems)/`.
struct FakeStemSeparator: StemSeparating {
    var speed: Double = 1

    func separate(
        input: URL, model: DJStemModel, outputDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DJStemResult {
        let seconds = (model == .htdemucsFT ? 12.0 : 7.0) / speed
        let steps = 50
        progress(0)
        for step in 1...steps {
            try await Task.sleep(for: .seconds(seconds / Double(steps)))
            progress(Double(step) / Double(steps))
        }
        let name = input.deletingPathExtension().lastPathComponent
        let folder = outputDirectory.appending(path: "\(name) (Stems)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stems: [String: URL] = [:]
        for stem in model.stemNames {
            let url = folder.appending(path: "\(stem).wav")
            try FakeAudio.writeSilentWAV(to: url)
            stems[stem] = url
        }
        return DJStemResult(stems: stems)
    }
}

/// "Installs" in a few seconds of status lines and remembers that with a
/// marker file under `<supportDirectory>/fake-engines/` (never in the real
/// `runtime/`). A repair counts up, then writes a silent WAV to `output`.
actor FakeApolloRuntime: ApolloRepairing {
    private let marker: URL
    private let speed: Double
    private var installing: String?

    init(supportDirectory: URL, speed: Double = 1) {
        marker = supportDirectory.appending(path: "fake-engines/apollo-installed")
        self.speed = speed
    }

    func state() async -> DJApolloSetupState {
        if let installing { return .installing(installing) }
        return FileManager.default.fileExists(atPath: marker.path) ? .ready : .notInstalled
    }

    func install(progress: @escaping @Sendable (String) -> Void) async throws {
        let steps: [(String, Int)] = [
            ("Downloading uv", 4),
            ("Installing Python 3.12", 6),
            ("Installing PyTorch and dependencies", 14),
            ("Downloading Apollo model weights", 10),
            ("Checking the model", 4),
        ]
        defer { installing = nil }
        for (message, ticks) in steps {
            for tick in 0..<ticks {
                let line = ticks > 6 ? "\(message)… \(tick * 100 / ticks)%" : "\(message)…"
                installing = line
                progress(line)
                try await Task.sleep(for: .milliseconds(Int(250 / speed)))
            }
        }
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: marker)
        progress("Ready")
    }

    func repair(
        input: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw FakeEngineError("Apollo isn't set up yet.")
        }
        let steps = 40
        progress(0)
        status("Loading model")
        for step in 1...steps {
            if step == 4 { status("Repairing on MPS") }
            try await Task.sleep(for: .seconds(8.0 / speed / Double(steps)))
            progress(Double(step) / Double(steps))
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FakeAudio.writeSilentWAV(to: output)
        return output
    }

    func cancel() async {
        // Task cancellation already stops the sleep; the real bridge kills its process here.
    }

    func reset() async throws {
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }
}

struct FakeEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum FakeHash {
    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func of(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

enum FakeAudio {
    /// A second of 16-bit stereo silence at 44.1 kHz.
    static func writeSilentWAV(to url: URL, seconds: Double = 1) throws {
        let sampleRate: UInt32 = 44_100, channels: UInt16 = 2, bits: UInt16 = 16
        let dataSize = UInt32(Double(sampleRate) * seconds) * UInt32(channels) * UInt32(bits / 8)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(channels)
        append(sampleRate); append(sampleRate * UInt32(channels) * UInt32(bits / 8)); append(channels * bits / 8); append(bits)
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url, options: .atomic)
    }
}

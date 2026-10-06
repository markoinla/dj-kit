import Foundation
import Testing
@testable import QualityKit

@Suite("Synthetic PCM files")
struct SyntheticTests {
    let dir = Synth.tempDir()

    @Test func fullBandWavIsLossless() async throws {
        let url = dir.appendingPathComponent("full.wav")
        try Synth.writePCM(Synth.pink(), to: url, seconds: 30)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(r.container == "wav")
        #expect(r.isLosslessContainer)
        #expect(r.sampleRate == 44_100)
        #expect(r.channels == 2)
        #expect(abs(r.duration - 30) < 0.01)
        #expect((r.cutoffHz ?? 0) > 21_000)
        #expect(r.verdict == .lossless, "\(r.summary)")
    }

    @Test(arguments: [11_000.0, 16_000.0, 19_000.0])
    func lowPassedWavIsFakeLossless(cutoff: Double) async throws {
        let url = dir.appendingPathComponent("lp\(Int(cutoff)).wav")
        try Synth.writePCM(Synth.pink(cutoff: cutoff), to: url, seconds: 30)
        let r = try await QualityAnalyzer.analyze(url)
        let est = try #require(r.cutoffHz)
        #expect(abs(est - cutoff) < 250, "estimated \(est)")
        #expect(r.verdict == .fakeLossless, "\(r.summary)")
    }

    @Test func sixteenKHzSummaryNamesTheSource() async throws {
        let url = dir.appendingPathComponent("lp16.aiff")
        try Synth.writePCM(Synth.pink(cutoff: 16_000), to: url, seconds: 20)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(r.container == "aiff")
        #expect(r.verdict == .fakeLossless)
        #expect(r.summary.contains("16.0 kHz"), "\(r.summary)")
        #expect(r.summary.contains("128 kbps"), "\(r.summary)")
    }

    @Test func cutoffAt20_5kHzCountsAsLossless() async throws {
        let url = dir.appendingPathComponent("lp205.wav")
        try Synth.writePCM(Synth.pink(cutoff: 20_500), to: url, seconds: 20)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(abs((r.cutoffHz ?? 0) - 20_500) < 250)
        #expect(r.verdict == .lossless, "\(r.summary)")
    }

    @Test func gradualRollOffIsNotACliff() async throws {
        // Steep-ish but natural roll-off above 8 kHz (≈24 dB/octave), no brick wall.
        let samples = Synth.noise(sampleRate: 44_100) { f in
            guard f >= 20 else { return 0 }
            let base = 1 / sqrt(f)
            return f > 8_000 ? base * pow(8_000 / f, 2) : base
        }
        let url = dir.appendingPathComponent("gradual.wav")
        try Synth.writePCM(samples, to: url, seconds: 20)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(r.verdict == .lossless, "\(r.summary)")
    }

    @Test func silenceIsUnknown() async throws {
        let url = dir.appendingPathComponent("silence.wav")
        try Synth.writePCM([Float](repeating: 0, count: 44_100), to: url, seconds: 10)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(r.cutoffHz == nil)
        #expect(r.verdict == .unknown, "\(r.summary)")
    }

    @Test func mostlySilentTrackStillMeasured() async throws {
        // Silence with a 16 kHz-band burst in the middle third: silent windows must be skipped, not averaged in.
        let burst = Synth.pink(cutoff: 16_000)
        var samples = [Float](repeating: 0, count: 44_100 * 30)
        for i in (44_100 * 10)..<(44_100 * 20) { samples[i] = burst[i % burst.count] }
        let url = dir.appendingPathComponent("sparse.wav")
        try Synth.writePCM(samples, to: url)
        let r = try await QualityAnalyzer.analyze(url)
        #expect(abs((r.cutoffHz ?? 0) - 16_000) < 250)
        #expect(r.verdict == .fakeLossless, "\(r.summary)")
    }

    @Test func sixMinuteTrackIsFast() async throws {
        let url = dir.appendingPathComponent("long.wav")
        try Synth.writePCM(Synth.pink(), to: url, seconds: 360)
        let clock = ContinuousClock()
        var report: QualityReport?
        let elapsed = try await clock.measure { report = try await QualityAnalyzer.analyze(url) }
        print("6-minute WAV analyzed in \(elapsed)")
        #expect(elapsed < .seconds(2))
        #expect(report?.verdict == .lossless)
    }

    @Test func missingFileThrows() async {
        await #expect(throws: QualityError.self) {
            try await QualityAnalyzer.analyze(dir.appendingPathComponent("nope.wav"))
        }
    }

    @Test func reportRoundTripsThroughJSON() async throws {
        let url = dir.appendingPathComponent("json.wav")
        try Synth.writePCM(Synth.pink(cutoff: 16_000), to: url, seconds: 10)
        let r = try await QualityAnalyzer.analyze(url)
        let back = try JSONDecoder().decode(QualityReport.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}

/// Real lossy encodes made with macOS's afconvert (AAC; macOS has no MP3 encoder).
@Suite("afconvert AAC encodes")
struct AACTests {
    let dir = Synth.tempDir()

    func source() throws -> URL {
        let url = dir.appendingPathComponent("src.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Synth.writePCM(Synth.pink(seed: 7), to: url, seconds: 30)
        }
        return url
    }

    func encode(kbps: Int) throws -> URL {
        let out = dir.appendingPathComponent("aac\(kbps).m4a")
        let status = try Synth.afconvert(["-f", "m4af", "-d", "aac", "-b", "\(kbps * 1000)", try source().path, out.path])
        try #require(status == 0)
        return out
    }

    @Test func lowBitrateAACIsLowQuality() async throws {
        let r = try await QualityAnalyzer.analyze(try encode(kbps: 96))
        print("AAC 96k:", r.summary, r.cutoffHz ?? -1)
        #expect(r.container == "m4a")
        #expect(!r.isLosslessContainer)
        let kbps = try #require(r.declaredBitrateKbps)
        #expect(kbps > 70 && kbps < 130)
        #expect(r.verdict == .lowQuality, "\(r.summary)")
    }

    @Test func highBitrateAACIsGoodLossy() async throws {
        let r = try await QualityAnalyzer.analyze(try encode(kbps: 256))
        print("AAC 256k:", r.summary, r.cutoffHz ?? -1)
        #expect((r.declaredBitrateKbps ?? 0) >= 192)
        #expect((r.cutoffHz ?? 0) > 16_500)
        #expect(r.verdict == .goodLossy, "\(r.summary)")
    }

    @Test(arguments: [("WAVE", "LEI16", "wav"), ("AIFF", "BEI16", "aiff"), ("flac", "flac", "flac")])
    func decodedLowBitrateAACIsFakeLossless(fileType: String, format: String, ext: String) async throws {
        let m4a = try encode(kbps: 96)
        let out = dir.appendingPathComponent("fake-\(ext).\(ext)")
        let status = try Synth.afconvert(["-f", fileType, "-d", format, m4a.path, out.path])
        try #require(status == 0, "afconvert to \(ext) failed")
        let r = try await QualityAnalyzer.analyze(out)
        print("AAC 96k → \(ext):", r.summary, r.cutoffHz ?? -1)
        #expect(r.container == ext)
        #expect(r.isLosslessContainer)
        #expect(r.verdict == .fakeLossless, "\(r.summary)")
    }
}

@Suite("Verdict rules")
struct ClassifyTests {
    func classify(_ lossless: Bool, kbps: Int?, hz: Double?, cliff: Bool = true, sr: Double = 44_100) -> QualityVerdict {
        QualityAnalyzer.classify(isLossless: lossless, codecLabel: lossless ? "FLAC" : "MP3", bitrateKbps: kbps,
                                 cutoff: hz.map { CutoffEstimate(hz: $0, isCliff: cliff, dropDb: cliff ? 40 : 0) },
                                 sampleRate: sr, usableFrames: 100).0
    }

    @Test func rules() {
        #expect(classify(true, kbps: 900, hz: 21_800) == .lossless)
        #expect(classify(true, kbps: 900, hz: 16_000) == .fakeLossless)
        #expect(classify(true, kbps: 900, hz: 19_000) == .fakeLossless)
        #expect(classify(true, kbps: 900, hz: 17_000, cliff: false) == .lossless)
        #expect(classify(true, kbps: nil, hz: 10_500, sr: 22_050) == .lossless)  // full band at 22.05 kHz
        #expect(classify(false, kbps: 320, hz: 20_000) == .goodLossy)
        #expect(classify(false, kbps: 192, hz: 19_000) == .goodLossy)
        #expect(classify(false, kbps: 128, hz: 16_000) == .lowQuality)
        #expect(classify(false, kbps: 320, hz: 16_000) == .lowQuality)  // upsampled 128k
        #expect(classify(false, kbps: 160, hz: 17_500) == .lowQuality)  // grey zone: bitrate breaks the tie
        #expect(classify(false, kbps: 256, hz: 17_500) == .goodLossy)
        #expect(classify(false, kbps: nil, hz: 17_500) == .goodLossy)
        #expect(classify(false, kbps: nil, hz: 19_500) == .goodLossy)
        #expect(classify(false, kbps: nil, hz: nil) == .unknown)
        #expect(classify(true, kbps: nil, hz: nil) == .unknown)
    }

    /// The cutoff, when measured, outranks the average bitrate.
    @Test func measuredCutoffBeatsAverageBitrate() {
        // A VBR MP3 averaging 184 kbps whose highs reach 18.8 kHz.
        #expect(classify(false, kbps: 184, hz: 18_800) == .goodLossy)
        #expect(classify(false, kbps: 128, hz: 18_000) == .goodLossy)
        #expect(classify(false, kbps: 191, hz: 17_999) == .lowQuality)
        // Bitrate still can't rescue a low cutoff.
        #expect(classify(false, kbps: 320, hz: 16_500) == .lowQuality)
    }

    /// No cutoff (too little audio): the bitrate is all there is.
    @Test func bitrateIsTheFallbackWithoutACutoff() {
        func verdict(_ kbps: Int?, frames: Int) -> QualityVerdict {
            QualityAnalyzer.classify(isLossless: false, codecLabel: "MP3", bitrateKbps: kbps, cutoff: nil,
                                     sampleRate: 44_100, usableFrames: frames).0
        }
        #expect(verdict(184, frames: 4) == .lowQuality)
        #expect(verdict(128, frames: 0) == .lowQuality)
        #expect(verdict(256, frames: 4) == .unknown)
        #expect(verdict(nil, frames: 4) == .unknown)
    }

    @Test func vbrSummaryReadsGood() {
        let (v, s) = QualityAnalyzer.classify(isLossless: false, codecLabel: "MP3", bitrateKbps: 184,
                                              cutoff: CutoffEstimate(hz: 18_800, isCliff: true, dropDb: 40),
                                              sampleRate: 44_100, usableFrames: 100)
        #expect(v == .goodLossy)
        #expect(s == "MP3 184 kbps, highs reach 18.8 kHz — good")
    }

    @Test func summaries() {
        let (v, s) = QualityAnalyzer.classify(isLossless: false, codecLabel: "MP3", bitrateKbps: 128,
                                              cutoff: CutoffEstimate(hz: 16_000, isCliff: true, dropDb: 50),
                                              sampleRate: 44_100, usableFrames: 100)
        #expect(v == .lowQuality)
        #expect(s == "MP3 128 kbps, cuts off at 16.0 kHz — low quality")
    }
}

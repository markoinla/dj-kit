import AVFoundation
import Foundation
import Testing
@testable import LoudnessKit

// Compliance cases synthesized from EBU Tech 3341 (loudness metering,
// "EBU mode") and EBU Tech 3342 (loudness range). Levels are per channel,
// as the documents state them.

/// A sine of `seconds` at `dBFS` peak amplitude.
func sine(_ frequency: Double, dBFS: Double, seconds: Double, sampleRate: Double, phaseDegrees: Double = 0) -> [Float] {
    let amplitude = pow(10, dBFS / 20)
    let n = Int((seconds * sampleRate).rounded())
    let step = 2 * Double.pi * frequency / sampleRate
    let phase = phaseDegrees * .pi / 180
    return (0..<n).map { Float(amplitude * sin(Double($0) * step + phase)) }
}

/// A 20 ms raised-cosine fade in and out: an abrupt start out of silence is a
/// real intersample overshoot (Gibbs), which the true-peak tests aren't about.
func faded(_ samples: [Float], sampleRate: Double) -> [Float] {
    let n = min(Int(sampleRate * 0.02), samples.count / 2)
    var out = samples
    for i in 0..<n {
        let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
        out[i] *= g
        out[out.count - 1 - i] *= g
    }
    return out
}

/// Stereo (or `channels`) 1 kHz in level/duration sections.
func sections(_ parts: [(dBFS: Double, seconds: Double)], sampleRate: Double = 48_000) -> [Float] {
    var out: [Float] = []
    for part in parts {
        // Restart each section at the running phase so there are no clicks.
        let n = Int((part.seconds * sampleRate).rounded())
        let amplitude = pow(10, part.dBFS / 20)
        let start = out.count
        out.reserveCapacity(start + n)
        for i in 0..<n {
            out.append(Float(amplitude * sin(2 * Double.pi * 1000 * Double(start + i) / sampleRate)))
        }
    }
    return out
}

func measure(_ channels: [[Float]], sampleRate: Double = 48_000, chunk: Int = 4_096) -> LoudnessReport {
    let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: channels.count)
    let n = channels[0].count
    var start = 0
    while start < n {
        let end = min(start + chunk, n)
        meter.process(channels.map { Array($0[start..<end]) })
        start = end
    }
    return meter.finish()
}

@Suite("EBU Tech 3341 — integrated loudness")
struct IntegratedLoudnessTests {
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func case1Sine23(sampleRate: Double) {
        let s = sine(1000, dBFS: -23, seconds: 20, sampleRate: sampleRate)
        let r = measure([s, s], sampleRate: sampleRate)
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
        #expect(abs(r.duration - 20) < 0.001)
    }

    @Test func case2Sine33() {
        let s = sine(1000, dBFS: -33, seconds: 20, sampleRate: 48_000)
        let r = measure([s, s])
        #expect(abs(r.integratedLUFS - -33) <= 0.1, "\(r.integratedLUFS)")
    }

    @Test func case3RelativeGate() {
        let s = sections([(-36, 10), (-23, 60), (-36, 10)])
        let r = measure([s, s])
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
    }

    @Test func case4AbsoluteAndRelativeGates() {
        let s = sections([(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)])
        let r = measure([s, s])
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
    }

    @Test func case5AlternatingLevels() {
        // −26 / −20 / −26 dBFS, 20.1 s each: the gated mean lands on −23.
        let s = sections([(-26, 20.1), (-20, 20.1), (-26, 20.1)])
        let r = measure([s, s])
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
    }

    @Test func case6FiveChannels() {
        // L, R at −28 dBFS, C at −24 dBFS, Ls, Rs at −30 dBFS (weighted 1.41).
        let front = sine(1000, dBFS: -28, seconds: 20, sampleRate: 48_000)
        let centre = sine(1000, dBFS: -24, seconds: 20, sampleRate: 48_000)
        let surround = sine(1000, dBFS: -30, seconds: 20, sampleRate: 48_000)
        let r = measure([front, front, centre, surround, surround])
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
        // 5.1 with a loud LFE: the LFE doesn't count.
        let lfe = sine(60, dBFS: -6, seconds: 20, sampleRate: 48_000)
        let r6 = measure([front, front, centre, lfe, surround, surround])
        #expect(abs(r6.integratedLUFS - -23) <= 0.1, "\(r6.integratedLUFS)")
    }

    @Test func silenceIsMinusInfinity() {
        let r = measure([[Float](repeating: 0, count: 48_000 * 2)])
        #expect(r.isSilent)
        #expect(r.integratedLUFS == -.infinity)
        #expect(r.samplePeakDBFS == -.infinity)
        #expect(r.loudnessRangeLU == nil)
    }

    @Test func belowAbsoluteGateIsSilent() {
        let s = sine(1000, dBFS: -75, seconds: 5, sampleRate: 48_000)
        #expect(measure([s, s]).isSilent)
    }

    @Test func chunkSizeDoesNotMatter() {
        let s = sections([(-30, 3), (-18, 4)])
        let a = measure([s, s], chunk: 1_000)
        let b = measure([s, s], chunk: 65_536)
        let c = measure([s, s], chunk: 4_801)
        #expect(abs(a.integratedLUFS - b.integratedLUFS) < 1e-9)
        #expect(abs(a.integratedLUFS - c.integratedLUFS) < 1e-9)
        #expect(a.truePeakDBTP == b.truePeakDBTP)
    }

    @Test func coefficientsMatchBS1770At48k() {
        let c = LoudnessMeter.kWeightingCoefficients(sampleRate: 48_000)
        let published = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                         1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        for (mine, theirs) in zip(c, published) {
            #expect(abs(mine - theirs) < 1e-6, "\(mine) vs \(theirs)")
        }
    }
}

@Suite("EBU Tech 3342 — loudness range")
struct LoudnessRangeTests {
    @Test(arguments: [
        ([(-20.0, 20.0), (-30.0, 20.0)], 10.0),
        ([(-20.0, 20.0), (-15.0, 20.0)], 5.0),
        ([(-40.0, 20.0), (-20.0, 20.0)], 20.0),
        ([(-50.0, 20.0), (-35.0, 20.0), (-20.0, 20.0), (-35.0, 20.0), (-50.0, 20.0)], 15.0),
    ])
    func cases1to4(parts: [(Double, Double)], expected: Double) throws {
        let s = sections(parts.map { (dBFS: $0.0, seconds: $0.1) })
        let r = measure([s, s])
        let lra = try #require(r.loudnessRangeLU)
        #expect(abs(lra - expected) <= 1, "LRA \(lra), expected \(expected)")
    }

    @Test func steadyToneHasNoRange() throws {
        let s = sine(1000, dBFS: -20, seconds: 10, sampleRate: 48_000)
        let lra = try #require(measure([s, s]).loudnessRangeLU)
        #expect(lra < 0.1)
    }

    @Test func tooShortForShortTerm() {
        let s = sine(1000, dBFS: -20, seconds: 2, sampleRate: 48_000)
        #expect(measure([s, s]).loudnessRangeLU == nil)
    }
}

@Suite("True peak (BS.1770-4 Annex 2, EBU Tech 3341 tolerances +0.2 / −0.4 dB)")
struct TruePeakTests {
    func expectTruePeak(_ r: LoudnessReport, _ expected: Double, _ comment: String = "") {
        #expect(r.truePeakDBTP <= expected + 0.2 && r.truePeakDBTP >= expected - 0.4,
                "true peak \(r.truePeakDBTP), expected \(expected) \(comment)")
        #expect(r.truePeakDBTP >= r.samplePeakDBFS - 1e-9)
    }

    /// fs/4 at −6 dBFS with phase offsets: the sample peak drops (to −9 dB at
    /// 45°) but the true peak stays at −6.
    @Test(arguments: [0.0, 45.0, 60.0, 67.5])
    func quarterSampleRate(phase: Double) {
        let s = faded(sine(12_000, dBFS: -6, seconds: 1, sampleRate: 48_000, phaseDegrees: phase), sampleRate: 48_000)
        let r = measure([s], sampleRate: 48_000)
        expectTruePeak(r, -6, "phase \(phase)")
        if phase == 45 { #expect(abs(r.samplePeakDBFS - (-6 - 3.01)) < 0.05, "\(r.samplePeakDBFS)") }
    }

    /// An intersample over: full-scale fs/4 at 45° never has a sample above
    /// −3 dBFS but reconstructs to 0 dBTP.
    @Test func intersampleOverAt44k() {
        let s = faded(sine(11_025, dBFS: 0, seconds: 1, sampleRate: 44_100, phaseDegrees: 45), sampleRate: 44_100)
        let r = measure([s, s], sampleRate: 44_100)
        #expect(abs(r.samplePeakDBFS - -3.01) < 0.05)
        expectTruePeak(r, 0)
    }

    @Test(arguments: [(997.0, 44_100.0), (5_000.0, 44_100.0), (17_000.0, 44_100.0), (19_000.0, 48_000.0),
                      (19_997.0, 96_000.0), (30_000.0, 96_000.0)])
    func sinesAcrossTheBand(frequency: Double, sampleRate: Double) {
        let s = faded(sine(frequency, dBFS: -1, seconds: 1, sampleRate: sampleRate, phaseDegrees: 33), sampleRate: sampleRate)
        expectTruePeak(measure([s, s], sampleRate: sampleRate), -1, "\(frequency) Hz @ \(sampleRate)")
    }

    @Test func factors() {
        #expect(TruePeakDetector.factor(for: 44_100) == 8)
        #expect(TruePeakDetector.factor(for: 48_000) == 8)
        #expect(TruePeakDetector.factor(for: 96_000) == 4)
        #expect(TruePeakDetector.factor(for: 192_000) == 2)
    }
}

@Suite("Normalizer")
struct NormalizerTests {
    func report(_ lufs: Double, tp: Double) -> LoudnessReport {
        LoudnessReport(integratedLUFS: lufs, truePeakDBTP: tp, samplePeakDBFS: tp - 0.3, loudnessRangeLU: 5,
                       duration: 300, sampleRate: 44_100, channels: 2)
    }

    @Test func loudTrackComesDown() {
        let plan = Normalizer.gain(for: report(-6.2, tp: 0.4), targetLUFS: -10, ceilingDBTP: -1)
        #expect(abs(plan.gainDB - -3.8) < 1e-9)
        #expect(!plan.limitedByCeiling)
        #expect(abs(plan.resultingLUFS - -10) < 1e-9)
        #expect(abs(plan.resultingTruePeakDBTP - -3.4) < 1e-9)
    }

    @Test func quietTrackGoesUp() {
        let plan = Normalizer.gain(for: report(-14, tp: -6), targetLUFS: -10, ceilingDBTP: -1)
        #expect(abs(plan.gainDB - 4) < 1e-9)
        #expect(!plan.limitedByCeiling)
    }

    @Test func peakyTrackIsCapped() {
        let plan = Normalizer.gain(for: report(-15, tp: -3), targetLUFS: -10, ceilingDBTP: -1)
        #expect(plan.limitedByCeiling)
        #expect(abs(plan.gainDB - 2) < 1e-9)
        #expect(abs(plan.resultingLUFS - -13) < 1e-9)
        #expect(abs(plan.resultingTruePeakDBTP - -1) < 1e-9)
    }

    /// Already over the ceiling: the plan cuts, even though the target wanted more.
    @Test func sourceOverTheCeilingIsCut() {
        let plan = Normalizer.gain(for: report(-12, tp: 0.5), targetLUFS: -10, ceilingDBTP: -1)
        #expect(plan.limitedByCeiling)
        #expect(abs(plan.gainDB - -1.5) < 1e-9)
    }

    @Test func exactlyAtTheCeilingIsNotCapped() {
        let plan = Normalizer.gain(for: report(-14, tp: -5), targetLUFS: -10, ceilingDBTP: -1)
        #expect(!plan.limitedByCeiling)
        #expect(abs(plan.resultingTruePeakDBTP - -1) < 1e-9)
    }

    @Test func silenceGetsNoGain() {
        let r = LoudnessReport(integratedLUFS: -.infinity, truePeakDBTP: -.infinity, samplePeakDBFS: -.infinity,
                               loudnessRangeLU: nil, duration: 10, sampleRate: 44_100, channels: 2)
        let plan = Normalizer.gain(for: r, targetLUFS: -10, ceilingDBTP: -1)
        #expect(plan.gainDB == 0)
        #expect(!plan.limitedByCeiling)
    }

    /// Measure, apply the plan's gain, measure again: lands on the target.
    @Test func gainRoundTrip() {
        var state: UInt64 = 42
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 1_000_000) / 1_000_000 * 0.4 - 0.2
        }
        let left = (0..<(44_100 * 12)).map { _ in noise() }
        let right = (0..<(44_100 * 12)).map { _ in noise() }
        let before = measure([left, right], sampleRate: 44_100)
        let plan = Normalizer.gain(for: before, targetLUFS: -14, ceilingDBTP: -1)
        let g = Float(plan.linearGain)
        let after = measure([left.map { $0 * g }, right.map { $0 * g }], sampleRate: 44_100)
        let expected = plan.limitedByCeiling ? plan.resultingLUFS : -14
        #expect(abs(after.integratedLUFS - expected) < 0.01, "\(after.integratedLUFS)")
        #expect(abs(after.truePeakDBTP - plan.resultingTruePeakDBTP) < 0.01)
    }
}

@Suite("Files")
struct FileTests {
    @Test func measuresA24BitWAV() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "loudnesskit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = sine(1000, dBFS: -23, seconds: 20, sampleRate: 44_100)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(s.count))!
            buffer.frameLength = AVAudioFrameCount(s.count)
            for c in 0..<2 { s.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: s.count) } }
            try file.write(from: buffer)
        }
        let r = try await LoudnessAnalyzer.measure(url)
        #expect(abs(r.integratedLUFS - -23) <= 0.1, "\(r.integratedLUFS)")
        #expect(abs(r.samplePeakDBFS - -23) < 0.01)
        #expect(abs(r.duration - 20) < 0.001)
        #expect(r.channels == 2 && r.sampleRate == 44_100)
    }

    @Test func unreadableFileThrows() async {
        await #expect(throws: LoudnessError.self) {
            try await LoudnessAnalyzer.measure(URL(filePath: "/nonexistent/x.wav"))
        }
    }
}

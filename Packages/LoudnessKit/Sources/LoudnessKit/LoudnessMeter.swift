import Accelerate
import Foundation

/// Streaming BS.1770-4 meter: feed it planar float audio in any chunk sizes,
/// then `finish()` for the report.
///
/// - K-weighting: the two BS.1770 biquads (high-shelf "pre-filter" and the
///   RLB high-pass), with coefficients derived for the actual sample rate
///   from the analog prototypes (the same derivation as libebur128), run in
///   double precision.
/// - Mean square per 100 ms segment, channel-weighted (L, R, C = 1, LFE = 0,
///   surrounds 1.41); momentary blocks are 4 segments (400 ms, 75% overlap),
///   short-term windows 30 segments (3 s, every 100 ms).
/// - Integrated: absolute gate −70 LUFS, then relative gate −10 LU below the
///   mean of what passed. LRA (EBU Tech 3342): short-term values, absolute
///   gate −70, relative gate −20 LU, 95th − 10th percentile.
/// - True peak: polyphase windowed-sinc interpolation, 8× up to 48 kHz,
///   4× up to 96 kHz, 2× above (BS.1770-4 Annex 2 asks for ≥ 4× at 48 kHz).
public final class LoudnessMeter {
    public let sampleRate: Double
    public let channelCount: Int
    /// BS.1770 channel weights for this layout.
    public let weights: [Double]

    private let setup: vDSP_biquad_SetupD
    private var delays: [[Double]]
    private let segmentLength: Int
    private var segmentFill = 0
    private var segmentSum = 0.0
    /// Channel-weighted sum of squares per finished 100 ms segment.
    private var segments: [Double] = []
    private var peaks: [TruePeakDetector]
    private var samplePeak: Float = 0
    private var frames = 0
    private var asDouble: [Double] = []
    private var filtered: [Double] = []

    public init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0 && channelCount > 0)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        weights = Self.channelWeights(channelCount)
        setup = vDSP_biquad_CreateSetupD(Self.kWeightingCoefficients(sampleRate: sampleRate), 2)!
        delays = Array(repeating: Array(repeating: 0, count: 2 * 2 + 2), count: channelCount)
        segmentLength = max(1, Int((sampleRate / 10).rounded()))
        let phases = TruePeakDetector.phaseFilters(factor: TruePeakDetector.factor(for: sampleRate))
        peaks = Array(repeating: TruePeakDetector(phases: phases), count: channelCount)
    }

    deinit {
        vDSP_biquad_DestroySetupD(setup)
    }

    /// L, R, C = 1; for 5.0 (L R C Ls Rs) and 5.1 (L R C LFE Ls Rs) the
    /// surrounds get 1.41 and LFE 0. Anything else: 1 each.
    static func channelWeights(_ count: Int) -> [Double] {
        switch count {
        case 5: [1, 1, 1, 1.41, 1.41]
        case 6: [1, 1, 1, 0, 1.41, 1.41]
        default: Array(repeating: 1, count: count)
        }
    }

    /// The two K-weighting biquads as vDSP wants them: b0 b1 b2 a1 a2 per
    /// section (a0 = 1). At 48 kHz these are BS.1770's published values.
    public static func kWeightingCoefficients(sampleRate fs: Double) -> [Double] {
        // Stage 1: high shelf, +4 dB above ~1.7 kHz (head effects).
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = [
            (vh + vb * k / q + k * k) / a0,
            2 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0,
            (1 - k / q + k * k) / a0,
        ]
        // Stage 2: RLB high-pass at ~38 Hz.
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        let d = 1 + k / q + k * k
        let highpass = [1, -2, 1, 2 * (k * k - 1) / d, (1 - k / q + k * k) / d]
        return shelf + highpass
    }

    /// Feeds `frameCount` frames, one pointer per channel.
    public func process(_ channels: [UnsafePointer<Float>], frameCount n: Int) {
        precondition(channels.count == channelCount)
        guard n > 0 else { return }
        if asDouble.count < n {
            asDouble = [Double](repeating: 0, count: n)
            filtered = [Double](repeating: 0, count: n)
        }
        // Where this chunk's samples fall into 100 ms segments.
        var bounds = [0]
        var next = min(segmentLength - segmentFill, n)
        while true {
            bounds.append(next)
            if next == n { break }
            next = min(next + segmentLength, n)
        }
        var pieceSums = [Double](repeating: 0, count: bounds.count - 1)

        for (c, samples) in channels.enumerated() {
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(n))
            samplePeak = max(samplePeak, peak)
            peaks[c].process(samples, count: n)

            let weight = weights[c]
            guard weight > 0 else { continue }
            asDouble.withUnsafeMutableBufferPointer { x in
                vDSP_vspdp(samples, 1, x.baseAddress!, 1, vDSP_Length(n))
                filtered.withUnsafeMutableBufferPointer { y in
                    delays[c].withUnsafeMutableBufferPointer { delay in
                        vDSP_biquadD(setup, delay.baseAddress!, x.baseAddress!, 1, y.baseAddress!, 1, vDSP_Length(n))
                    }
                    for piece in 0..<(bounds.count - 1) {
                        var sum = 0.0
                        vDSP_svesqD(y.baseAddress! + bounds[piece], 1, &sum, vDSP_Length(bounds[piece + 1] - bounds[piece]))
                        pieceSums[piece] += weight * sum
                    }
                }
            }
        }
        for piece in 0..<pieceSums.count {
            segmentSum += pieceSums[piece]
            segmentFill += bounds[piece + 1] - bounds[piece]
            if segmentFill == segmentLength {
                segments.append(segmentSum)
                segmentSum = 0
                segmentFill = 0
            }
        }
        frames += n
    }

    /// Convenience for tests and small buffers: one array per channel.
    public func process(_ channels: [[Float]]) {
        let n = channels.first?.count ?? 0
        precondition(channels.allSatisfy { $0.count == n })
        var pointers: [UnsafePointer<Float>] = []
        func feed(_ index: Int) {
            if index == channels.count {
                process(pointers, frameCount: n)
                return
            }
            channels[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                feed(index + 1)
            }
        }
        feed(0)
    }

    /// The report for everything fed so far. Call once.
    public func finish() -> LoudnessReport {
        var truePeak = samplePeak
        for c in peaks.indices {
            peaks[c].flush()
            truePeak = max(truePeak, peaks[c].peak)
        }
        let blockEnergies = windowedEnergies(segmentsPerWindow: 4)
        let integrated: Double
        if let mean = Self.gatedMean(blockEnergies, relativeGateLU: -10) {
            integrated = Self.lufs(mean)
        } else {
            integrated = -.infinity
        }
        return LoudnessReport(
            integratedLUFS: integrated,
            truePeakDBTP: Self.decibels(Double(truePeak)),
            samplePeakDBFS: Self.decibels(Double(samplePeak)),
            loudnessRangeLU: loudnessRange(),
            duration: Double(frames) / sampleRate,
            sampleRate: sampleRate,
            channels: channelCount
        )
    }

    /// Mean square of every window of `count` consecutive segments (hop: one segment).
    private func windowedEnergies(segmentsPerWindow count: Int) -> [Double] {
        guard segments.count >= count else { return [] }
        let scale = 1 / Double(count * segmentLength)
        var out: [Double] = []
        out.reserveCapacity(segments.count - count + 1)
        var running = segments[0..<count].reduce(0, +)
        out.append(running * scale)
        for i in count..<segments.count {
            running += segments[i] - segments[i - count]
            out.append(max(running, 0) * scale)
        }
        return out
    }

    /// −70 LUFS as a mean square.
    static let absoluteGateEnergy = pow(10, (-70 + 0.691) / 10)

    static func lufs(_ energy: Double) -> Double {
        energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity
    }

    static func decibels(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    /// The energies that pass both gates (absolute −70 LUFS, relative to the
    /// absolutely-gated mean); nil when none do.
    static func gated(_ energies: [Double], relativeGateLU: Double) -> [Double]? {
        let passed = energies.filter { $0 > absoluteGateEnergy }
        guard !passed.isEmpty else { return nil }
        let relative = passed.reduce(0, +) / Double(passed.count) * pow(10, relativeGateLU / 10)
        let kept = passed.filter { $0 > relative }
        return kept.isEmpty ? nil : kept
    }

    static func gatedMean(_ energies: [Double], relativeGateLU: Double) -> Double? {
        guard let kept = gated(energies, relativeGateLU: relativeGateLU) else { return nil }
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// EBU Tech 3342: 3 s short-term loudness every 100 ms, gated (−70
    /// absolute, −20 LU relative), 95th minus 10th percentile.
    private func loudnessRange() -> Double? {
        let shortTerm = windowedEnergies(segmentsPerWindow: 30)
        guard let kept = Self.gated(shortTerm, relativeGateLU: -20) else { return nil }
        let levels = kept.map(Self.lufs).sorted()
        return Self.percentile(levels, 0.95) - Self.percentile(levels, 0.10)
    }

    /// Linear interpolation between closest ranks (numpy's default).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * t
    }
}

/// True-peak estimate for one channel: the largest magnitude of the signal
/// interpolated at `factor − 1` points between samples (the samples
/// themselves are the sample peak, which the meter tracks).
///
/// Interpolator: Kaiser-windowed sinc (β 5.65, ≈ 60 dB), 32 taps per phase,
/// cut off at the input's Nyquist frequency; each phase is normalised to unit
/// DC gain. Phase 0 would be the identity and is skipped.
struct TruePeakDetector {
    static let taps = 32

    static func factor(for sampleRate: Double) -> Int {
        sampleRate <= 48_000 ? 8 : sampleRate <= 96_000 ? 4 : 2
    }

    /// Filters for phases 1…factor−1, ready for `vDSP_conv` (correlation).
    static func phaseFilters(factor: Int) -> [[Float]] {
        let half = Double(taps / 2)
        let beta = 5.65
        return (1..<factor).map { phase in
            let d = Double(phase) / Double(factor)
            var coefficients = (0..<taps).map { j -> Double in
                let u = Double(j - taps / 2 + 1) - d    // distance from the interpolated point
                let sinc = u == 0 ? 1 : sin(.pi * u) / (.pi * u)
                let r = u / half
                let window = abs(r) >= 1 ? 0 : besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
                return sinc * window
            }
            let sum = coefficients.reduce(0, +)
            coefficients = coefficients.map { $0 / sum }
            return coefficients.map(Float.init)
        }
    }

    /// Modified Bessel function of the first kind, order 0 (series).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        let y = x * x / 4
        while term > 1e-12 * sum {
            term *= y / (k * k)
            sum += term
            k += 1
        }
        return sum
    }

    private let phases: [[Float]]
    /// The last `taps − 1` input samples, then the current chunk.
    private var work: [Float]
    private var out: [Float] = []
    private(set) var peak: Float = 0

    init(phases: [[Float]]) {
        self.phases = phases
        work = [Float](repeating: 0, count: Self.taps - 1)
    }

    mutating func process(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0, !phases.isEmpty else { return }
        let history = Self.taps - 1
        work.removeSubrange(0..<(work.count - history))
        work.append(contentsOf: UnsafeBufferPointer(start: samples, count: n))
        if out.count < n { out = [Float](repeating: 0, count: n) }
        var best: Float = peak
        work.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                for filter in phases {
                    filter.withUnsafeBufferPointer { f in
                        vDSP_conv(input.baseAddress!, 1, f.baseAddress!, 1, output.baseAddress!, 1,
                                  vDSP_Length(n), vDSP_Length(Self.taps))
                    }
                    var m: Float = 0
                    vDSP_maxmgv(output.baseAddress!, 1, &m, vDSP_Length(n))
                    best = max(best, m)
                }
            }
        }
        peak = best
    }

    /// Runs the last samples through the filter (the interpolator looks ahead).
    mutating func flush() {
        let zeros = [Float](repeating: 0, count: Self.taps)
        zeros.withUnsafeBufferPointer { process($0.baseAddress!, count: $0.count) }
    }
}

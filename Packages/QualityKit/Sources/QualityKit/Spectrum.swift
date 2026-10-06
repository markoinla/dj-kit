import AVFoundation
import Accelerate

/// Averaged power spectrum of a track, in dB per FFT bin (bin 0 = DC, last bin just below Nyquist).
struct AveragedSpectrum: Sendable {
    var db: [Double]
    var binHz: Double
    var usableFrames: Int
}

struct CutoffEstimate: Sendable, Equatable {
    var hz: Double
    /// True when the highs end in a steep cliff (encoder low-pass) rather than a gradual roll-off.
    var isCliff: Bool
    /// Level drop across the edge (dB); 0 when no cliff.
    var dropDb: Double
}

enum Spectrum {
    /// Reads `windowCount` windows spread across the file and averages the power spectra
    /// of all non-silent FFT frames (mono mix-down, Hann window).
    static func average(file: AVAudioFile) throws -> AveragedSpectrum {
        let n = 1 << Thresholds.fftLog2n
        let half = n / 2
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let totalFrames = file.length
        let binHz = format.sampleRate / Double(n)

        let windowFrames = AVAudioFrameCount(n * Thresholds.framesPerWindow)
        guard totalFrames >= Int64(n), channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames)
        else { return AveragedSpectrum(db: [], binHz: binHz, usableFrames: 0) }

        guard let setup = vDSP_create_fftsetup(vDSP_Length(Thresholds.fftLog2n), FFTRadix(kFFTRadix2)) else {
            return AveragedSpectrum(db: [], binHz: binHz, usableFrames: 0)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var mono = [Float](repeating: 0, count: Int(windowFrames))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var accum = [Double](repeating: 0, count: half)
        var magsD = [Double](repeating: 0, count: half)
        var usable = 0

        let silenceRms = Float(pow(10, Thresholds.silenceRmsDb / 20))
        let first = Int64(Double(totalFrames) * Thresholds.edgeSkipFraction)
        let last = max(first, totalFrames - Int64(Double(totalFrames) * Thresholds.edgeSkipFraction) - Int64(windowFrames))
        let count = Thresholds.windowCount

        for w in 0..<count {
            let start = count == 1 ? first : first + (last - first) * Int64(w) / Int64(count - 1)
            file.framePosition = max(0, start)
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: windowFrames) } catch { continue }
            let got = Int(buffer.frameLength)
            guard got >= n, let data = buffer.floatChannelData else { continue }

            // Mono mix-down.
            mono.withUnsafeMutableBufferPointer { m in
                vDSP_mmov(data[0], m.baseAddress!, vDSP_Length(got), 1, vDSP_Length(got), vDSP_Length(got))
                for c in 1..<max(1, channels) {
                    vDSP_vadd(m.baseAddress!, 1, data[c], 1, m.baseAddress!, 1, vDSP_Length(got))
                }
                if channels > 1 {
                    var s = 1 / Float(channels)
                    vDSP_vsmul(m.baseAddress!, 1, &s, m.baseAddress!, 1, vDSP_Length(got))
                }
            }

            var offset = 0
            while offset + n <= got {
                var rms: Float = 0
                mono.withUnsafeBufferPointer { m in
                    vDSP_rmsqv(m.baseAddress! + offset, 1, &rms, vDSP_Length(n))
                    vDSP_vmul(m.baseAddress! + offset, 1, hann, 1, &frame, 1, vDSP_Length(n))
                }
                offset += n
                guard rms >= silenceRms else { continue }

                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(Thresholds.fftLog2n), FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                mags[0] = 0 // packed DC/Nyquist; DC is irrelevant here
                vDSP_vspdp(mags, 1, &magsD, 1, vDSP_Length(half))
                vDSP_vaddD(accum, 1, magsD, 1, &accum, 1, vDSP_Length(half))
                usable += 1
            }
        }

        guard usable > 0 else { return AveragedSpectrum(db: [], binHz: binHz, usableFrames: 0) }
        let floorPower = pow(10, Thresholds.floorDb / 10)
        let db = accum.map { 10 * log10(max($0 / Double(usable), floorPower)) }
        return AveragedSpectrum(db: db, binHz: binHz, usableFrames: usable)
    }

    /// Finds where the highs stop. Looks for the strongest cliff (a steep drop that stays down
    /// up to Nyquist); without one, takes the highest frequency still within reach of the mid band.
    static func estimateCutoff(_ spectrum: AveragedSpectrum) -> CutoffEstimate? {
        let s = spectrum.db
        let bins = s.count
        guard bins > 16, spectrum.binHz > 0 else { return nil }
        let binHz = spectrum.binHz
        let nyquist = Double(bins) * binHz

        // Light smoothing (~100 Hz) and a prefix sum for O(1) range means.
        let smooth = movingAverage(s, radius: max(1, Int((50 / binHz).rounded())))
        var prefix = [Double](repeating: 0, count: bins + 1)
        for i in 0..<bins { prefix[i + 1] = prefix[i] + smooth[i] }
        func mean(_ lo: Int, _ hi: Int) -> Double { // inclusive lo, exclusive hi
            let a = max(0, lo), b = min(bins, hi)
            return b > a ? (prefix[b] - prefix[a]) / Double(b - a) : -Double.infinity
        }

        let inner = max(1, Int(Thresholds.edgeInnerHz / binHz))
        let outer = max(inner + 2, Int(Thresholds.edgeOuterHz / binHz))
        let minBin = max(outer, Int(Thresholds.searchMinHz / binHz))
        let maxBin = bins - inner - 3

        var best: (bin: Int, drop: Double, pre: Double, post: Double)?
        if minBin < maxBin {
            for k in minBin..<maxBin {
                let pre = mean(k - outer, k - inner)
                let post = mean(k + inner, k + outer)
                let drop = pre - post
                guard drop >= Thresholds.cliffDropDb, drop > (best?.drop ?? -.infinity) else { continue }
                // Above the edge, the spectrum must stay down all the way up.
                let above = Array(smooth[(k + inner)..<bins]).sorted()
                let p90 = above[min(above.count - 1, Int(Double(above.count) * 0.9))]
                guard p90 <= pre - Thresholds.cliffStaysLowDb else { continue }
                best = (k, drop, pre, post)
            }
        }

        if let best {
            // Refine: highest bin near the edge still above the half-way level.
            let mid = (best.pre + best.post) / 2
            var edge = best.bin
            let lo = max(0, best.bin - outer), hi = min(bins - 1, best.bin + outer)
            for i in stride(from: hi, through: lo, by: -1) where smooth[i] >= mid { edge = i; break }
            return CutoffEstimate(hz: Double(edge) * binHz, isCliff: true, dropDb: best.drop)
        }

        // No cliff: full band or a natural roll-off. The cutoff is the highest frequency still within
        // `gradualDropDb` of the mid band (or Nyquist if the spectrum never falls that far).
        let ref = mean(Int(Thresholds.referenceLowHz / binHz), Int(Thresholds.referenceHighHz / binHz))
        for i in stride(from: bins - 1, through: 0, by: -1) where smooth[i] >= ref - Thresholds.gradualDropDb {
            let hz = i >= bins - 2 ? nyquist : Double(i) * binHz
            return CutoffEstimate(hz: hz, isCliff: false, dropDb: 0)
        }
        return nil
    }

    static func movingAverage(_ x: [Double], radius: Int) -> [Double] {
        let n = x.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<n).map { i in
            let a = max(0, i - radius), b = min(n, i + radius + 1)
            return (prefix[b] - prefix[a]) / Double(b - a)
        }
    }
}

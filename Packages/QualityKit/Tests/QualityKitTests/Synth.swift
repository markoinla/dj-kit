import AVFoundation
import Accelerate
import Foundation

/// Test signal synthesis: noise built in the frequency domain (one big inverse FFT, so it loops seamlessly).
enum Synth {
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// Noise with magnitude `shape(freqHz)` per bin and random phase. Length 2^log2n samples, peak-normalized to `peak`.
    static func noise(sampleRate: Double, log2n: Int = 21, seed: UInt64 = 1, peak: Float = 0.5,
                      shape: (Double) -> Double) -> [Float] {
        let n = 1 << log2n
        let half = n / 2
        var rng = Rng(state: seed)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        for k in 1..<half {
            let f = Double(k) * sampleRate / Double(n)
            let m = shape(f)
            guard m > 0 else { continue }
            let phase = rng.next() * 2 * .pi
            real[k] = Float(m * cos(phase))
            imag[k] = Float(m * sin(phase))
        }
        var out = [Float](repeating: 0, count: n)
        let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        var maxAbs: Float = 0
        vDSP_maxmgv(out, 1, &maxAbs, vDSP_Length(n))
        var scale = peak / max(maxAbs, 1e-12)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }

    /// Pink (1/f power) noise, brick-wall low-passed at `cutoff` (nil = full band).
    static func pink(sampleRate: Double = 44_100, cutoff: Double? = nil, seed: UInt64 = 1) -> [Float] {
        noise(sampleRate: sampleRate, seed: seed) { f in
            if let cutoff, f > cutoff { return 0 }
            return f < 20 ? 0 : 1 / sqrt(f)
        }
    }

    /// Writes `seconds` of `samples` (looped) to a stereo 16-bit PCM file (WAV/AIFF/CAF by extension).
    static func writePCM(_ samples: [Float], to url: URL, sampleRate: Double = 44_100, seconds: Double? = nil,
                         fileType: AudioFileTypeID? = nil) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased().hasPrefix("aif"),
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = seconds.map { Int($0 * sampleRate) } ?? samples.count
        let chunk = 1 << 16
        let fmt = file.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var written = 0
        while written < total {
            let len = min(chunk, total - written)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<len {
                let s = samples[(written + i) % samples.count]
                l[i] = s
                r[i] = s
            }
            buf.frameLength = AVAudioFrameCount(len)
            try file.write(from: buf)
            written += len
        }
    }

    @discardableResult
    static func afconvert(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QualityKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

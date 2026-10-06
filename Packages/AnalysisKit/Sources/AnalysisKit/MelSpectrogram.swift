// Beat This!'s input features, reproduced from beat_this/preprocessing.py (LogMelSpect):
// torchaudio MelSpectrogram at 22050 Hz, n_fft 1024, hop 441 (50 fps), periodic Hann window,
// centered frames with reflect padding, magnitude (power 1) scaled by 1/sqrt(n_fft)
// (normalized="frame_length"), 128 Slaney-scale mel bands 30–11000 Hz without filter
// normalization, then log1p(1000 · mel). vDSP on the CPU; ~30 ms for 6 minutes.
import AVFoundation
import Accelerate
import Foundation

enum MelSpectrogram {
  static let sampleRate = 22_050.0
  static let fftSize = 1024
  static let hop = 441
  static let bins = fftSize / 2 + 1  // 513
  static let bands = 128
  static let fMin = 30.0
  static let fMax = 11_000.0
  static let framesPerSecond = sampleRate / Double(hop)  // 50

  /// [bins × bands], row-major, as torchaudio.functional.melscale_fbanks(norm=None, "slaney").
  static let filterbank: [Float] = {
    func hzToMel(_ f: Double) -> Double {
      let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27
      return f >= minLogHz ? minLogMel + log(f / minLogHz) / logStep : f / fSp
    }
    func melToHz(_ m: Double) -> Double {
      let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27
      return m >= minLogMel ? minLogHz * exp(logStep * (m - minLogMel)) : m * fSp
    }
    let nyquist = Double(Int(sampleRate) / 2)  // torchaudio uses sample_rate // 2
    let melMin = hzToMel(fMin), melMax = hzToMel(fMax)
    let points = (0..<(bands + 2)).map { melToHz(melMin + (melMax - melMin) * Double($0) / Double(bands + 1)) }
    var fb = [Float](repeating: 0, count: bins * bands)
    for k in 0..<bins {
      let f = nyquist * Double(k) / Double(bins - 1)
      for m in 0..<bands {
        let down = (f - points[m]) / (points[m + 1] - points[m])
        let up = (points[m + 2] - f) / (points[m + 2] - points[m + 1])
        fb[k * bands + m] = Float(max(0, min(down, up)))
      }
    }
    return fb
  }()

  /// Periodic Hann window.
  static let window: [Float] = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }

  /// Log-mel frames of 22050 Hz mono audio: [frames × 128] row-major, frames = 1 + count / 441.
  /// Works in blocks of frames (no padded copy of the signal, no full magnitude matrix), so a long
  /// mix needs little beyond the signal and the result.
  static func compute(_ signal: [Float]) -> (values: [Float], frames: Int) {
    let n = signal.count
    guard n > fftSize / 2 else { return ([], 0) }
    let pad = fftSize / 2
    let frames = 1 + n / hop
    var mel = [Float](repeating: 0, count: frames * bands)
    let log2n = vDSP_Length(10)
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
    defer { vDSP_destroy_fftsetup(setup) }
    let block = 512
    let blocks = (frames + block - 1) / block
    // vDSP's real FFT returns 2× the DFT; torch.stft(normalized=True) divides by sqrt(n_fft).
    let scale = 1 / (2 * Float(fftSize).squareRoot())
    signal.withUnsafeBufferPointer { src in
      mel.withUnsafeMutableBufferPointer { dst in
        // Read-only input, disjoint output rows per block, and a setup vDSP allows to share.
        nonisolated(unsafe) let src = src.baseAddress!, dst = dst.baseAddress!, setup = setup
        DispatchQueue.concurrentPerform(iterations: blocks) { b in
          let first = b * block, count = min(frames, first + block) - first
          var magnitudes = [Float](repeating: 0, count: count * bins)
          var edge = [Float](repeating: 0, count: fftSize)
          var frame = [Float](repeating: 0, count: fftSize)
          var re = [Float](repeating: 0, count: fftSize / 2)
          var im = [Float](repeating: 0, count: fftSize / 2)
          re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
              var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
              for i in 0..<count {
                // Centered frames, reflect-padded at the ends (edge sample not repeated).
                let start = (first + i) * hop - pad
                if start >= 0 && start + fftSize <= n {
                  vDSP_vmul(src + start, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
                } else {
                  for j in 0..<fftSize {
                    let k = start + j
                    edge[j] = src[k < 0 ? -k : k >= n ? 2 * n - 2 - k : k]
                  }
                  vDSP_vmul(edge, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
                }
                frame.withUnsafeBufferPointer { f in
                  f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                  }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { m in
                  let row = m.baseAddress! + i * bins
                  row[0] = abs(rp[0]) * scale
                  row[bins - 1] = abs(ip[0]) * scale
                  for k in 1..<(fftSize / 2) {
                    row[k] = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot() * scale
                  }
                }
              }
            }
          }
          let out = dst + first * bands
          vDSP_mmul(magnitudes, 1, filterbank, 1, out, 1, vDSP_Length(count), vDSP_Length(bands), vDSP_Length(bins))
          var k: Float = 1000
          vDSP_vsmul(out, 1, &k, out, 1, vDSP_Length(count * bands))
          var total = Int32(count * bands)
          vvlog1pf(out, out, &total)
        }
      }
    }
    return (mel, frames)
  }

  /// Resamples mono audio to 22050 Hz with Core Audio's mastering-quality converter.
  static func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
    if rate == sampleRate || samples.isEmpty { return samples }
    guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let converter = AVAudioConverter(from: inFormat, to: outFormat),
      let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw BeatTrackerError.audio("Can't resample from \(rate) Hz") }
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let expected = Int((Double(samples.count) * sampleRate / rate).rounded())
    guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(expected + 1024)) else {
      throw BeatTrackerError.audio("Out of memory")
    }
    nonisolated(unsafe) var fed = false
    nonisolated(unsafe) let source = input
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if fed { outStatus.pointee = .endOfStream; return nil }
      fed = true
      outStatus.pointee = .haveData
      return source
    }
    if status == .error { throw BeatTrackerError.audio(error?.localizedDescription ?? "Resampling failed") }
    let count = min(Int(output.frameLength), expected)
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
  }
}

// Port of the STFT / iSTFT used by Apollo (look2hear/models/apollo.py, CC BY-SA 4.0, Kai Li and
// Yi Luo): torch.stft / torch.istft with n_fft 882, hop 441, periodic Hann window, center=True,
// reflect padding, onesided output.
//
// The DFT (size 882 = 2·3²·7²) is a matmul against a basis precomputed in Double, run on the
// CPU stream for precision (see Mode for why).
import Foundation
import MLX

struct Spectral {
  static let nfft = 882
  static let hop = 441
  static let bins = nfft / 2 + 1  // 442

  /// [882, 442] analysis bases with the window folded in: re = frames @ cos, im = frames @ sin.
  let analysisCos: MLXArray
  let analysisSin: MLXArray
  /// [442, 882] synthesis bases (inverse real DFT, 1/N, interior bins doubled, window folded in).
  let synthesisCos: MLXArray
  let synthesisSin: MLXArray
  let windowSquared: [Float]
  let window: MLXArray

  /// How the DFT is computed. Apollo divides every band by its own energy, so near-silent bands
  /// (everything above a lossy file's cutoff) amplify tiny absolute STFT errors; measured on the
  /// parity fixture (output SNR vs PyTorch fp32):
  ///   .cpuMatmul (default)  DFT basis matmul on the CPU stream (Accelerate, true fp32)  62.8 dB
  ///   .fft                  MLX GPU FFT (n=882 mixed radix)                             48.7 dB
  ///   .matmul               DFT matmul on the GPU — MLX runs fp32 matmuls as TF32 on M5
  ///                         GPUs unless MLX_ENABLE_TF32=0                               12.4 dB
  /// Override with APOLLO_MLX_STFT=cpu|fft|matmul. Cost on the CPU is a few ms per chunk.
  enum Mode: String { case fft, matmul, cpuMatmul = "cpu" }
  let mode: Mode = Mode(rawValue: ProcessInfo.processInfo.environment["APOLLO_MLX_STFT"] ?? "cpu") ?? .cpuMatmul

  init() {
    let n = Self.nfft, k = Self.bins
    let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
    var aCos = [Float](repeating: 0, count: n * k), aSin = aCos
    var sCos = [Float](repeating: 0, count: k * n), sSin = sCos
    for t in 0..<n {
      for f in 0..<k {
        // (t*f) mod n keeps the angle small, so the basis is accurate to Double rounding.
        let angle = 2 * Double.pi * Double((t * f) % n) / Double(n)
        let c = cos(angle), s = sin(angle)
        aCos[t * k + f] = Float(window[t] * c)
        aSin[t * k + f] = Float(-window[t] * s)
        let scale = (f == 0 || f == k - 1 ? 1.0 : 2.0) / Double(n) * window[t]
        sCos[f * n + t] = Float(scale * c)
        sSin[f * n + t] = Float(-scale * s)
      }
    }
    analysisCos = MLXArray(aCos, [n, k])
    analysisSin = MLXArray(aSin, [n, k])
    synthesisCos = MLXArray(sCos, [k, n])
    synthesisSin = MLXArray(sSin, [k, n])
    windowSquared = window.map { Float($0 * $0) }
    self.window = MLXArray(window.map { Float($0) })
  }

  static func frameCount(samples: Int) -> Int { samples / hop + 1 }

  /// x: [R, S] float32 (S > 441). Returns (re, im), each [R, T, 442].
  func stft(_ x: MLXArray) -> (MLXArray, MLXArray) {
    let length = x.dim(1)
    precondition(length > Self.nfft / 2, "STFT input must be longer than n_fft/2")
    let half = Self.nfft / 2
    let frames = Self.frameCount(samples: length)
    // Frame gather with reflect padding folded into the indices (torch center=True,
    // pad_mode="reflect"): frame f, tap t reads padded[f*hop + t].
    var index = [Int32](repeating: 0, count: frames * Self.nfft)
    for f in 0..<frames {
      for t in 0..<Self.nfft {
        var j = f * Self.hop + t - half
        if j < 0 { j = -j }
        if j >= length { j = 2 * (length - 1) - j }
        index[f * Self.nfft + t] = Int32(j)
      }
    }
    let windows = x.take(MLXArray(index, [frames, Self.nfft]), axis: 1)  // R, T, 882
    switch mode {
    case .fft:
      let z = rfft(windows * window, axis: -1)
      return (z.realPart(), z.imaginaryPart())
    case .matmul, .cpuMatmul:
      let dev: StreamOrDevice = mode == .cpuMatmul ? .cpu : .default
      return (matmul(windows, analysisCos, stream: dev), matmul(windows, analysisSin, stream: dev))
    }
  }

  /// re, im: [R, T, 442]. Returns [R, length] (torch.istft with center=True, length=length).
  /// Like torch, the imaginary parts of the DC and Nyquist bins are ignored.
  func istft(re: MLXArray, im: MLXArray, length: Int) -> MLXArray {
    let rows = re.dim(0), frames = re.dim(1), hop = Self.hop
    let windowed: MLXArray  // R, T, 882 (inverse DFT times the synthesis window)
    switch mode {
    case .fft:
      let z = re.asType(.complex64) + im * MLXArray(real: 0, imaginary: 1)
      windowed = irfft(z, n: Self.nfft, axis: -1) * window
    case .matmul, .cpuMatmul:
      let dev: StreamOrDevice = mode == .cpuMatmul ? .cpu : .default
      windowed = matmul(re, synthesisCos, stream: dev) + matmul(im, synthesisSin, stream: dev)
    }
    // Overlap-add with hop = n_fft/2: output block b = first half of frame b + second half of frame b-1.
    let zeros = MLXArray.zeros([rows, 1, hop], dtype: windowed.dtype)
    let first = concatenated([windowed[0..., 0..., 0..<hop], zeros], axis: 1)
    let second = concatenated([zeros, windowed[0..., 0..., hop...]], axis: 1)
    let total = (frames + 1) * hop
    let summed = (first + second).reshaped(rows, total)
    // Window-square envelope (what torch.istft divides by).
    var envelope = [Float](repeating: 0, count: total)
    for f in 0..<frames {
      for t in 0..<Self.nfft { envelope[f * hop + t] += windowSquared[t] }
    }
    let start = Self.nfft / 2
    precondition(start + length <= total, "iSTFT length exceeds the frames' span")
    let env = MLXArray(Array(envelope[start..<(start + length)]))
    return summed[0..., start..<(start + length)] / env
  }
}

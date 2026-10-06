// MLX port of Apollo: Band-sequence Modeling for High-Quality Audio Restoration
// (https://github.com/JusperLee/Apollo, look2hear/models/apollo.py at e84bcac) by Kai Li and Yi Luo.
// Licensed under CC BY-SA 4.0 — this adapted file is distributed under the same license.
//
// Inference-only, channels-last re-layout of the released configuration
// (sr 44100, win 20 ms, feature_dim 256, 6 layers, 80 bands = 79×5 bins + 1×47 bins):
//   STFT -> per-band [re/|b|, im/|b|, log|b|] -> RMSNorm -> 1x1 conv to 256
//   6× BSNet: Roformer across the 80 bands (per frame), then 3 ConvActNorm1d blocks along time
//   per-band RMSNorm -> 1x1 conv -> GLU -> complex spectrum -> iSTFT
// Every 1x1 conv is a matmul with an [in, out] weight; the 79 equal bands run as one batched
// matmul. Weight names are produced by WeightConversion.swift / tools/convert_weights.py.
import Foundation
import MLX

public enum ApolloPrecision: String, Sendable, CaseIterable {
  case fp32, fp16, bf16
  var dtype: DType {
    switch self {
    case .fp32: .float32
    case .fp16: .float16
    case .bf16: .bfloat16
    }
  }
}

public enum ApolloMLXError: Error, LocalizedError {
  case missingWeight(String)
  case badWeights(String)
  case checkpoint(String)
  case audio(String)
  case download(String)

  public var errorDescription: String? {
    switch self {
    case .missingWeight(let n): "Repair model weights are missing tensor \(n)"
    case .badWeights(let m), .checkpoint(let m), .audio(let m), .download(let m): m
    }
  }
}

/// The Apollo network. Not Sendable (holds MLXArrays); own it from one actor/thread.
final class ApolloModel {
  static let sampleRate = 44_100
  static let bands = 80
  static let equalBands = 79
  static let bandWidth = 5
  static let lastBandWidth = Spectral.bins - equalBands * bandWidth  // 47
  static let featureDim = 256
  static let heads = 8
  static let headDim = featureDim / heads  // 32
  static let layers = 6
  static let kernel = 7
  static let rmsEps: Float = 1e-5
  static let powerEps: Float = Float.ulpOfOne  // torch.finfo(torch.float32).eps

  let precision: ApolloPrecision
  let spectral = Spectral()
  private let w: [String: MLXArray]
  /// Like torch.autocast: the residual stream and norms stay fp32 and only matmul/conv inputs
  /// are cast to the compute dtype (true), or everything runs in the compute dtype (false).
  /// Measured: no accuracy gain for fp16 (51.4 vs 52.0 dB vs PyTorch) and ~10% slower, so the
  /// default is the latter; APOLLO_MLX_RESIDUAL=fp32 selects the former.
  let fp32Residual = ProcessInfo.processInfo.environment["APOLLO_MLX_RESIDUAL"] == "fp32"
  var stream: DType { fp32Residual ? .float32 : precision.dtype }
  /// Depthwise time conv as MLX grouped conv1d (true) or as 7 shifted multiply-adds.
  var groupedDepthwise = ProcessInfo.processInfo.environment["APOLLO_MLX_DW"] != "shift"

  init(weights: [String: MLXArray], precision: ApolloPrecision) throws {
    self.precision = precision
    if precision == .fp32 {
      // MLX runs fp32 matmuls as TF32 on GPUs with neural accelerators (M5) unless told not to;
      // that costs ~10 dB of agreement with PyTorch. The flag is read once per process, at the
      // first matmul, so this only takes effect if nothing in the process has used MLX yet.
      setenv("MLX_ENABLE_TF32", "0", 0)
    }
    var converted: [String: MLXArray] = [:]
    for (name, array) in weights {
      // RoPE tables and the band-split bottleneck stay fp32 (they see raw log-power features).
      let keepFP32 = name.hasPrefix("rope.") || name.hasPrefix("bn") || name.hasSuffix("norm")
      converted[name] = keepFP32 ? array.asType(.float32) : array.asType(precision.dtype)
    }
    // Depthwise kernel in MLX conv layout [out=256, k=7, in/groups=1].
    for l in 0..<Self.layers {
      for j in 0..<3 {
        let key = "layers.\(l).seq.\(j).dw_w"
        guard let dw = converted[key] else { throw ApolloMLXError.missingWeight(key) }
        converted["layers.\(l).seq.\(j).dw_conv"] = dw.transposed(1, 0).expandedDimensions(axis: 2)
      }
    }
    self.w = converted
    try validate()
    eval(Array(w.values))
  }

  private func validate() throws {
    let expected: [String: [Int]] = [
      "bn.norm": [79, 11], "bn.w": [79, 11, 256], "bn.b": [79, 256],
      "bn_last.norm": [95], "bn_last.w": [95, 256], "bn_last.b": [256],
      "rope.cos": [80, 32], "rope.sin": [80, 32],
      "head.norm": [79, 256], "head.w": [79, 256, 20], "head.b": [79, 20],
      "head_last.norm": [256], "head_last.w": [256, 188], "head_last.b": [188],
      "layers.5.band.qkv": [256, 768], "layers.5.band.mlp_in": [256, 2048],
      "layers.5.band.mlp_out": [1024, 256], "layers.5.seq.2.fc1_w": [256, 1024],
    ]
    for (name, shape) in expected {
      guard let a = w[name] else { throw ApolloMLXError.missingWeight(name) }
      if a.shape != shape {
        throw ApolloMLXError.badWeights("Tensor \(name) has shape \(a.shape), expected \(shape)")
      }
    }
  }

  private func p(_ name: String) -> MLXArray { w[name]! }

  /// Matmul in the weight's dtype (autocast-style input cast).
  private func mm(_ a: MLXArray, _ name: String) -> MLXArray {
    let wt = p(name)
    return matmul(a.asType(wt.dtype), wt)
  }

  // MARK: - building blocks

  private static func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

  /// RMSNorm over the last axis with an arbitrary (broadcastable) weight; statistics in fp32.
  private static func rms(_ x: MLXArray, _ weight: MLXArray) -> MLXArray {
    let xf = x.asType(.float32)
    let norm = xf * rsqrt(mean(xf * xf, axis: -1, keepDims: true) + rmsEps)
    return norm.asType(x.dtype) * weight
  }

  private static func rms256(_ x: MLXArray, _ weight: MLXArray) -> MLXArray {
    MLXFast.rmsNorm(x, weight: weight.asType(x.dtype), eps: rmsEps)
  }

  /// Interleaved RoPE ("traditional"): pairs (x0, x1) -> (x0 cos - x1 sin, x1 cos + x0 sin).
  private func rope(_ x: MLXArray) -> MLXArray {
    let shape = x.shape
    let pairs = x.reshaped(Array(shape.dropLast()) + [Self.headDim / 2, 2])
    let rotated = stacked([-pairs[.ellipsis, 1], pairs[.ellipsis, 0]], axis: -1).reshaped(shape)
    let cos = p("rope.cos").asType(x.dtype), sin = p("rope.sin").asType(x.dtype)
    return x * cos + rotated * sin
  }

  // MARK: - forward

  /// Band-split bottleneck. x: [R, S] fp32 -> [R*T, 80, 256] (band layout) and T.
  func features(_ x: MLXArray) -> (MLXArray, Int) {
    let rows = x.dim(0)
    let (re, im) = spectral.stft(x.asType(.float32))
    let frames = re.dim(1)
    let n = rows * frames
    let eq = Self.equalBands * Self.bandWidth
    let re79 = re[0..., 0..., 0..<eq].reshaped(n, Self.equalBands, Self.bandWidth)
    let im79 = im[0..., 0..., 0..<eq].reshaped(n, Self.equalBands, Self.bandWidth)
    let pow79 = sqrt(sum(re79 * re79 + im79 * im79, axis: -1, keepDims: true) + Self.powerEps)
    var f79 = concatenated([re79 / pow79, im79 / pow79, log(pow79)], axis: -1)  // n, 79, 11
    f79 = Self.rms(f79, p("bn.norm"))
    f79 = matmul(f79.transposed(1, 0, 2), p("bn.w")) + p("bn.b").expandedDimensions(axis: 1)
    let reL = re[0..., 0..., eq...].reshaped(n, Self.lastBandWidth)
    let imL = im[0..., 0..., eq...].reshaped(n, Self.lastBandWidth)
    let powL = sqrt(sum(reL * reL + imL * imL, axis: -1, keepDims: true) + Self.powerEps)
    var fL = concatenated([reL / powL, imL / powL, log(powL)], axis: -1)  // n, 95
    fL = matmul(Self.rms(fL, p("bn_last.norm")), p("bn_last.w")) + p("bn_last.b")
    let h = concatenated([f79.transposed(1, 0, 2), fL.expandedDimensions(axis: 1)], axis: 1)
    return (h.asType(stream), frames)
  }

  /// Roformer across bands. x: [N, 80, 256].
  private func bandNet(_ x: MLXArray, layer l: Int) -> MLXArray {
    let pre = "layers.\(l).band."
    let n = x.dim(0), bands = x.dim(1)
    let qkv = mm(Self.rms256(x, p(pre + "norm")), pre + "qkv")
      .reshaped(n, bands, Self.heads, 3 * Self.headDim).transposed(0, 2, 1, 3)  // n, 8, 80, 96
    let d = Self.headDim
    let q = rope(qkv[.ellipsis, 0..<d])
    let k = rope(qkv[.ellipsis, d..<(2 * d)])
    let v = qkv[.ellipsis, (2 * d)..<(3 * d)]
    let scale = 1 / Float(d).squareRoot()
    let scores = matmul(q * scale, k.transposed(0, 1, 3, 2))
    let attn = softmax(scores.asType(.float32), axis: -1, precise: true).asType(v.dtype)
    let a = matmul(attn, v).transposed(0, 2, 1, 3).reshaped(n, bands, Self.featureDim)
    var out = x + mm(a, pre + "out")
    // MLP: SiLU(conv) then chunk; the gate gets a second SiLU (as upstream does).
    let g = Self.silu(mm(Self.rms256(out, p(pre + "mlp_norm")), pre + "mlp_in"))
    let half = 4 * Self.featureDim
    let gated = Self.silu(g[.ellipsis, 0..<half]) * g[.ellipsis, half...]
    out = out + mm(gated, pre + "mlp_out")
    return out
  }

  /// ICB block: x [M, T, 256] (M = R*80), depthwise k7 conv along T.
  private func convBlock(_ x: MLXArray, layer l: Int, block j: Int) -> MLXArray {
    let pre = "layers.\(l).seq.\(j)."
    let t = x.dim(1)
    var d: MLXArray
    if groupedDepthwise {
      d = conv1d(x.asType(precision.dtype), p(pre + "dw_conv"), padding: Self.kernel / 2, groups: Self.featureDim)
    } else {
      let xp = padded(x.asType(precision.dtype), widths: [0, [Self.kernel / 2, Self.kernel / 2], 0])
      let kw = p(pre + "dw_w")
      d = xp[0..., 0..<t, 0...] * kw[0]
      for k in 1..<Self.kernel { d = d + xp[0..., k..<(k + t), 0...] * kw[k] }
    }
    d = (d + p(pre + "dw_b")).asType(stream)
    d = Self.silu(mm(Self.rms256(d, p(pre + "norm")), pre + "fc1_w") + p(pre + "fc1_b"))
    d = mm(d, pre + "fc2_w") + p(pre + "fc2_b")
    return x + d
  }

  /// One BSNet layer on band layout [R*T, 80, 256].
  func layer(_ h: MLXArray, index l: Int, rows: Int, frames: Int) -> MLXArray {
    let b = bandNet(h, layer: l)
    var s = b.reshaped(rows, frames, Self.bands, Self.featureDim).transposed(0, 2, 1, 3)
      .reshaped(rows * Self.bands, frames, Self.featureDim)
    for j in 0..<3 { s = convBlock(s, layer: l, block: j) }
    return s.reshaped(rows, Self.bands, frames, Self.featureDim).transposed(0, 2, 1, 3)
      .reshaped(rows * frames, Self.bands, Self.featureDim)
  }

  /// Output heads -> waveform. h: [R*T, 80, 256].
  func synthesize(_ h: MLXArray, rows: Int, frames: Int, length: Int) -> MLXArray {
    let n = h.dim(0)
    let bw = Self.bandWidth
    var o79 = Self.rms(h[0..., 0..<Self.equalBands, 0...], p("head.norm"))
    o79 = mm(o79.transposed(1, 0, 2), "head.w") + p("head.b").expandedDimensions(axis: 1)
    o79 = (o79[.ellipsis, 0..<(2 * bw)] * sigmoid(o79[.ellipsis, (2 * bw)...])).asType(.float32)
    o79 = o79.transposed(1, 0, 2)  // n, 79, 10
    let lw = Self.lastBandWidth
    var oL = mm(Self.rms256(h[0..., Self.equalBands, 0...], p("head_last.norm")), "head_last.w")
      + p("head_last.b")
    oL = (oL[.ellipsis, 0..<(2 * lw)] * sigmoid(oL[.ellipsis, (2 * lw)...])).asType(.float32)
    let eq = Self.equalBands * bw
    let re = concatenated(
      [o79[.ellipsis, 0..<bw].reshaped(n, eq), oL[.ellipsis, 0..<lw]], axis: -1)
    let im = concatenated(
      [o79[.ellipsis, bw...].reshaped(n, eq), oL[.ellipsis, lw...]], axis: -1)
    return spectral.istft(
      re: re.reshaped(rows, frames, Spectral.bins), im: im.reshaped(rows, frames, Spectral.bins),
      length: length)
  }

  /// Full forward. x: [R, S] (each row an independent mono signal). Evaluates layer by layer
  /// so the lazy graph (and peak memory) stays bounded. `capture` sees intermediates.
  func callAsFunction(_ x: MLXArray, capture: ((String, MLXArray) -> Void)? = nil) -> MLXArray {
    let rows = x.dim(0), length = x.dim(1)
    var (h, frames) = features(x)
    eval(h)
    capture?("features", h)
    for l in 0..<Self.layers {
      h = layer(h, index: l, rows: rows, frames: frames)
      eval(h)
      capture?("layer\(l)", h)
    }
    let y = synthesize(h, rows: rows, frames: frames, length: length)
    eval(y)
    return y
  }
}

// MLX port of the Beat This! network (https://github.com/CPJKU/beat_this, MIT;
// beat_this/model/beat_tracker.py + roformer.py), inference only, channels-last.
//
//   log-mel [B, T, 128] -> BatchNorm1d -> conv 4×3 stride (4,1) -> BN -> GELU      [B, 32 f, T, 32 c]
//   3× (partial transformer over frequency, then over time -> conv 2×3 stride (2,1) -> BN -> GELU)
//   [B, 4, T, 256] -> (c f) flatten -> linear 1024→D -> 6 RoFormer blocks -> RMSNorm -> linear → 2
//   beat logit = beat + downbeat output (SumHead)
// Attention: RMSNorm, fused qkv, interleaved rotary embedding (dim 32, base 10000, positions
// restart in every sequence), per-head sigmoid gates. RMSNorm is F.normalize·sqrt(d)·γ, i.e.
// x / rms(x) · γ. Any transformer width works (512 for final0, 128 for small0); heads = D / 32.
import Foundation
import MLX

final class BeatThisModel {
  static let headDim = 32
  static let bnEps: Float = 1e-5
  /// Sequences longer than this use MLX's fused attention (head dim zero-padded to 64).
  static let fusedMinLength = 64

  let width: Int
  let layers: Int
  let dtype: DType
  private var w: [String: MLXArray] = [:]

  /// - Parameter weights: the BeatThis state dict (no "model." prefix), e.g. from safetensors.
  init(weights raw: [String: MLXArray], dtype: DType = .float32) throws {
    self.dtype = dtype
    func get(_ name: String) throws -> MLXArray {
      guard let a = raw[name] else { throw BeatTrackerError.badWeights("Missing tensor \(name)") }
      return a.asType(.float32)
    }
    guard let lin = raw["frontend.linear.weight"], lin.ndim == 2, lin.dim(1) == 1024 else {
      throw BeatTrackerError.badWeights("Not a Beat This! checkpoint")
    }
    width = lin.dim(0)
    layers = Set(raw.keys.compactMap { k -> Int? in
      guard k.hasPrefix("transformer_blocks.layers.") else { return nil }
      return Int(k.split(separator: ".")[2])
    }).count

    var w: [String: MLXArray] = [:]
    func batchNorm(_ name: String) throws {
      let weight = try get(name + ".weight"), bias = try get(name + ".bias")
      let mean = try get(name + ".running_mean"), variance = try get(name + ".running_var")
      let scale = weight * rsqrt(variance + Self.bnEps)
      w[name + ".scale"] = scale
      w[name + ".shift"] = bias - mean * scale
    }
    func linear(_ name: String, bias: Bool) throws {
      w[name + ".w"] = try get(name + ".weight").transposed(1, 0).asType(dtype)
      if bias { w[name + ".b"] = try get(name + ".bias").asType(dtype) }
    }
    func conv(_ name: String) throws {  // torch [O, I, H, W] -> MLX [O, H, W, I]
      w[name] = try get(name + ".weight").transposed(0, 2, 3, 1).asType(dtype)
    }
    func attention(_ p: String) throws {
      w[p + ".norm"] = try get(p + ".norm.gamma").asType(dtype)
      try linear(p + ".to_qkv", bias: false)
      try linear(p + ".to_gates", bias: true)
      try linear(p + ".to_out.0", bias: false)
    }
    func feedForward(_ p: String) throws {
      w[p + ".norm"] = try get(p + ".net.0.gamma").asType(dtype)
      try linear(p + ".net.1", bias: true)
      try linear(p + ".net.4", bias: true)
    }
    try batchNorm("frontend.stem.bn1d")
    try conv("frontend.stem.conv2d")
    try batchNorm("frontend.stem.bn2d")
    for b in 0..<3 {
      let p = "frontend.blocks.\(b)"
      for d in ["F", "T"] {
        try attention("\(p).partial.attn\(d)")
        try feedForward("\(p).partial.ff\(d)")
      }
      try conv("\(p).conv2d")
      try batchNorm("\(p).norm")
    }
    try linear("frontend.linear", bias: true)
    for l in 0..<layers {
      try attention("transformer_blocks.layers.\(l).0")
      try feedForward("transformer_blocks.layers.\(l).1")
    }
    w["transformer_blocks.norm"] = try get("transformer_blocks.norm.gamma").asType(dtype)
    try linear("task_heads.beat_downbeat_lin", bias: true)
    self.w = w
    eval(Array(w.values))
  }

  private func p(_ name: String) -> MLXArray { w[name]! }

  private static func gelu(_ x: MLXArray) -> MLXArray {
    x * 0.5 * (1 + erf(x * Float(0.5).squareRoot()))
  }

  private func rms(_ x: MLXArray, _ name: String) -> MLXArray {
    MLXFast.rmsNorm(x, weight: p(name), eps: 1e-12)
  }

  private func linear(_ x: MLXArray, _ name: String) -> MLXArray {
    let y = matmul(x, p(name + ".w"))
    if let b = w[name + ".b"] { return y + b }
    return y
  }

  private func batchNorm(_ x: MLXArray, _ name: String) -> MLXArray {
    (x * p(name + ".scale") + p(name + ".shift")).asType(dtype)
  }

  /// x: [N, L, C] -> [N, L, C].
  private func attention(_ x: MLXArray, _ name: String) -> MLXArray {
    let n = x.dim(0), l = x.dim(1), c = x.dim(2)
    let heads = c / Self.headDim
    let xn = rms(x, name + ".norm")
    let qkv = linear(xn, name + ".to_qkv").reshaped(n, l, 3, heads, Self.headDim).transposed(2, 0, 3, 1, 4)
    let q = MLXFast.RoPE(qkv[0], dimensions: Self.headDim, traditional: true, base: 10_000, scale: 1, offset: 0)
    let k = MLXFast.RoPE(qkv[1], dimensions: Self.headDim, traditional: true, base: 10_000, scale: 1, offset: 0)
    let scale = 1 / Float(Self.headDim).squareRoot()
    var o: MLXArray
    if l > Self.fusedMinLength {
      // MLX's fused (flash) attention has no head-dim-32 kernel; zero-padding q, k and v to 64
      // leaves every dot product and the kept output columns unchanged.
      let pad: [IntOrPair] = [0, 0, 0, [0, Self.headDim]]
      o = MLXFast.scaledDotProductAttention(
        queries: padded(q, widths: pad), keys: padded(k, widths: pad), values: padded(qkv[2], widths: pad),
        scale: scale, mask: nil)[.ellipsis, 0..<Self.headDim]
    } else {
      o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: qkv[2], scale: scale, mask: nil)
    }
    let gates = sigmoid(linear(xn, name + ".to_gates"))  // N, L, H
    o = o * gates.transposed(0, 2, 1).expandedDimensions(axis: -1)
    return linear(o.transposed(0, 2, 1, 3).reshaped(n, l, c), name + ".to_out.0")
  }

  private func feedForward(_ x: MLXArray, _ name: String) -> MLXArray {
    linear(Self.gelu(linear(rms(x, name + ".norm"), name + ".net.1")), name + ".net.4")
  }

  /// Attention + FF across frequency, then across time. x: [B, F, T, C].
  private func partial(_ x: MLXArray, block: Int) -> MLXArray {
    let b = x.dim(0), f = x.dim(1), t = x.dim(2), c = x.dim(3)
    let pre = "frontend.blocks.\(block).partial."
    var y = x.transposed(0, 2, 1, 3).reshaped(b * t, f, c)
    y = y + attention(y, pre + "attnF")
    y = y + feedForward(y, pre + "ffF")
    y = y.reshaped(b, t, f, c).transposed(0, 2, 1, 3).reshaped(b * f, t, c)
    y = y + attention(y, pre + "attnT")
    y = y + feedForward(y, pre + "ffT")
    return y.reshaped(b, f, t, c)
  }

  /// Log-mel chunks [B, T, 128] (fp32) -> beat logits [B, T] (fp32). Evaluates block by block,
  /// which keeps the peak allocation near one block's intermediates at no measurable cost.
  func callAsFunction(_ spect: MLXArray) -> MLXArray {
    let b = spect.dim(0), t = spect.dim(1)
    var h = spect * p("frontend.stem.bn1d.scale") + p("frontend.stem.bn1d.shift")
    h = h.transposed(0, 2, 1).expandedDimensions(axis: -1).asType(dtype)  // B, 128, T, 1
    h = conv2d(h, p("frontend.stem.conv2d"), stride: [4, 1], padding: [0, 1])
    h = Self.gelu(batchNorm(h, "frontend.stem.bn2d"))
    for blk in 0..<3 {
      h = partial(h, block: blk)
      h = conv2d(h, p("frontend.blocks.\(blk).conv2d"), stride: [2, 1], padding: [0, 1])
      h = Self.gelu(batchNorm(h, "frontend.blocks.\(blk).norm"))
      eval(h)
    }
    // [B, F=4, T, C=256] -> [B, T, (C F)]
    h = h.transposed(0, 2, 3, 1).reshaped(b, t, h.dim(3) * h.dim(1))
    h = linear(h, "frontend.linear")
    for l in 0..<layers {
      h = h + attention(h, "transformer_blocks.layers.\(l).0")
      h = h + feedForward(h, "transformer_blocks.layers.\(l).1")
      eval(h)
    }
    h = rms(h, "transformer_blocks.norm")
    let out = linear(h, "task_heads.beat_downbeat_lin").asType(.float32)
    return out[0..., 0..., 0] + out[0..., 0..., 1]
  }
}

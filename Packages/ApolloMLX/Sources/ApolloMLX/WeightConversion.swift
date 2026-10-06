// Converts the official Apollo checkpoint (JusperLee/Apollo pytorch_model.bin, CC BY-SA 4.0)
// into the channels-last layout ApolloModel loads. Mirrors tools/convert_weights.py exactly.
import Foundation
import MLX

enum WeightConversion {
  static let equalBands = 79

  /// torch state dict (name -> shape, values) -> ApolloMLX tensors.
  static func convert(_ sd: [String: (shape: [Int], values: [Float])]) throws -> [String: MLXArray] {
    func g(_ name: String) throws -> MLXArray {
      guard let t = sd[name] else { throw ApolloMLXError.missingWeight(name) }
      return MLXArray(t.values, t.shape)
    }
    /// Conv1d weight [out, in, 1] -> matmul weight [in, out].
    func conv(_ name: String) throws -> MLXArray { try g(name).squeezed(axis: 2).transposed(1, 0) }

    var out: [String: MLXArray] = [:]
    let nb = equalBands
    out["bn.norm"] = stacked(try (0..<nb).map { try g("BN.\($0).0.weight") })
    out["bn.w"] = stacked(try (0..<nb).map { try conv("BN.\($0).1.weight") })
    out["bn.b"] = stacked(try (0..<nb).map { try g("BN.\($0).1.bias") })
    out["bn_last.norm"] = try g("BN.\(nb).0.weight")
    out["bn_last.w"] = try conv("BN.\(nb).1.weight")
    out["bn_last.b"] = try g("BN.\(nb).1.bias")
    let layers = Set(sd.keys.filter { $0.hasPrefix("net.") }.compactMap { Int($0.split(separator: ".")[1]) })
    for l in layers.sorted() {
      var p = "net.\(l).band_net.", q = "layers.\(l).band."
      out[q + "norm"] = try g(p + "input_norm.weight")
      out[q + "qkv"] = try conv(p + "weight.weight")
      out[q + "out"] = try conv(p + "output.weight")
      out[q + "mlp_norm"] = try g(p + "MLP.0.weight")
      out[q + "mlp_in"] = try conv(p + "MLP.1.weight")
      out[q + "mlp_out"] = try conv(p + "MLP_output.weight")
      for j in 0..<3 {
        p = "net.\(l).seq_net.blocks.\(j).conv."
        q = "layers.\(l).seq.\(j)."
        out[q + "dw_w"] = try g(p + "0.weight").squeezed(axis: 1).transposed(1, 0)  // 7, 256
        out[q + "dw_b"] = try g(p + "0.bias")
        out[q + "norm"] = try g(p + "1.weight")
        out[q + "fc1_w"] = try conv(p + "2.weight")
        out[q + "fc1_b"] = try g(p + "2.bias")
        out[q + "fc2_w"] = try conv(p + "4.weight")
        out[q + "fc2_b"] = try g(p + "4.bias")
      }
    }
    out["rope.cos"] = try g("net.0.band_net.cos_freq")[0..<80]
    out["rope.sin"] = try g("net.0.band_net.sin_freq")[0..<80]
    out["head.norm"] = stacked(try (0..<nb).map { try g("output.\($0).0.weight") })
    out["head.w"] = stacked(try (0..<nb).map { try conv("output.\($0).1.weight") })
    out["head.b"] = stacked(try (0..<nb).map { try g("output.\($0).1.bias") })
    out["head_last.norm"] = try g("output.\(nb).0.weight")
    out["head_last.w"] = try conv("output.\(nb).1.weight")
    out["head_last.b"] = try g("output.\(nb).1.bias")
    // Materialize contiguous copies so the saved file is self-contained.
    for (k, v) in out { out[k] = contiguous(v) }
    eval(Array(out.values))
    return out
  }

  /// pytorch_model.bin -> apollo-mlx.safetensors (written atomically).
  static func convertCheckpoint(_ checkpoint: URL, to destination: URL) throws {
    let sd = try TorchCheckpoint.readStateDict(checkpoint)
    let tensors = try convert(sd)
    let tmp = destination.deletingLastPathComponent()
      .appendingPathComponent(".partial-\(UUID().uuidString).safetensors")
    try save(
      arrays: tensors,
      metadata: ["format": "apollo-mlx", "version": "1", "source": "huggingface.co/JusperLee/Apollo@c68bd80"],
      url: tmp)
    _ = try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: tmp, to: destination)
  }
}

/// Public conversion entry point (used by `apollo-mlx convert`).
public enum ApolloWeights {
  public static func convert(checkpoint: URL, to destination: URL) throws {
    try WeightConversion.convertCheckpoint(checkpoint, to: destination)
  }
}

// apollo-mlx — command-line front end for ApolloMLX.
//
//   apollo-mlx <input> <output.wav> [--weights W.safetensors | --models-dir DIR]
//              [--precision fp32|fp16|bf16] [--chunk-seconds 5] [--overlap-seconds 0.5]
//              [--pad-seconds 1] [--format pcm24|float]
//   apollo-mlx prepare [--models-dir DIR]                 download + convert weights
//   apollo-mlx convert <pytorch_model.bin> <out.safetensors>
//   apollo-mlx parity --weights W --reference ref.safetensors [--precision P] [--save out.safetensors]
import ApolloMLX
import Foundation
import MLX

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("apollo-mlx: \(msg)\n".utf8))
  exit(1)
}
func log(_ msg: String) { FileHandle.standardError.write(Data("\(msg)\n".utf8)) }

@MainActor func run() async throws {
  if ProcessInfo.processInfo.environment["APOLLO_MLX_DEVICE"] == "cpu" { Device.setDefault(device: .cpu) }
  var positional: [String] = []
  var flags: [String: String] = [:]
  var argv = CommandLine.arguments.dropFirst().makeIterator()
  while let a = argv.next() {
    if a.hasPrefix("--") {
      guard let v = argv.next() else { fail("missing value for \(a)") }
      flags[String(a.dropFirst(2))] = v
    } else {
      positional.append(a)
    }
  }
  func url(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
  let modelsDir = flags["models-dir"].map(url) ?? ApolloMLXRepairer.defaultModelsDirectory
  let precision: ApolloPrecision = {
    guard let p = flags["precision"] else { return .fp16 }
    guard let v = ApolloPrecision(rawValue: p) else { fail("unknown precision \(p)") }
    return v
  }()

  func metrics(_ a: [Float], _ ref: [Float]) -> (maxAbs: Float, snr: Double) {
    var m: Float = 0
    var num = 0.0, den = 0.0
    for i in ref.indices {
      let d = a[i] - ref[i]
      m = max(m, abs(d))
      num += Double(ref[i]) * Double(ref[i])
      den += Double(d) * Double(d)
    }
    return (m, 10 * log10(num / max(den, 1e-30)))
  }

  switch positional.first {
  case "prepare":
    let r = ApolloMLXRepairer(modelsDirectory: modelsDir)
    try await r.prepare { log($0) }
    print(await r.weightsURL.path)

  case "convert":
    guard positional.count == 3 else { fail("usage: apollo-mlx convert <pytorch_model.bin> <out.safetensors>") }
    let t0 = Date()
    try ApolloWeights.convert(checkpoint: url(positional[1]), to: url(positional[2]))
    log(String(format: "converted in %.2f s", Date().timeIntervalSince(t0)))

  case "parity":
    guard let w = flags["weights"], let refPath = flags["reference"] else {
      fail("usage: apollo-mlx parity --weights W --reference ref.safetensors")
    }
    let ref = try loadArrays(url: url(refPath))
    guard let input = ref["input"], let refOut = ref["output"] else { fail("reference lacks input/output") }
    let rows = input.dim(1), n = input.dim(2)
    let x = input.reshaped(rows, n).asArray(Float.self)
    let r = ApolloMLXRepairer(weightsURL: url(w), options: .init(precision: precision))
    _ = try await r.forwardForTesting([Array(x[0..<n])])  // warm-up (kernel compilation)
    let t0 = Date()
    let (out, captured) = try await r.forwardForTesting(
      (0..<rows).map { Array(x[($0 * n)..<(($0 + 1) * n)]) }, capture: ["features", "layer0"])
    let dt = Date().timeIntervalSince(t0)
    print("precision \(precision.rawValue): forward \(String(format: "%.3f", dt)) s for \(Double(n) / 44_100) s x \(rows) ch")
    // Intermediates: torch [R, 80, 256, T] -> ours [R*T, 80, 256]
    for name in ["features", "layer0"] {
      guard let refT = ref[name], let ours = captured[name] else { continue }
      let refBand = refT.transposed(0, 3, 1, 2).asArray(Float.self)
      let (m, s) = metrics(ours.values, refBand)
      print("  \(name): max abs \(m), SNR \(String(format: "%.1f", s)) dB (ref max \(refBand.map(abs).max()!))")
    }
    let flatRef = refOut.reshaped(rows, n).asArray(Float.self)
    let flatOut = out.flatMap { $0 }
    let (m, s) = metrics(flatOut, flatRef)
    print("  output: max abs \(m), SNR \(String(format: "%.1f", s)) dB")
    if let ref64 = ref["output64"] {
      let (m64, s64) = metrics(flatOut, ref64.reshaped(rows, n).asArray(Float.self))
      print("  output vs torch fp64: max abs \(m64), SNR \(String(format: "%.1f", s64)) dB")
    }
    if let save = flags["save"] {
      var arrays = ["output": MLXArray(flatOut, [1, rows, n])]
      for (k, v) in captured { arrays[k] = MLXArray(v.values, v.shape) }
      try MLX.save(arrays: arrays, url: url(save))
    }

  case let inputPath? where positional.count == 2:
    let plan = ChunkPlan(
      chunkSeconds: Double(flags["chunk-seconds"] ?? "5")!, overlapSeconds: Double(flags["overlap-seconds"] ?? "0.5")!,
      padSeconds: Double(flags["pad-seconds"] ?? "1")!)
    let format: AudioIO.WAVFormat = flags["format"] == "float" ? .float32 : .pcm24
    let r = ApolloMLXRepairer(
      modelsDirectory: modelsDir, weightsURL: flags["weights"].map(url),
      options: .init(precision: precision, plan: plan, outputFormat: format))
    if flags["weights"] == nil { try await r.prepare { log($0) } }
    let t0 = Date()
    let last = LockedValue(-1)
    try await r.repair(input: url(inputPath), output: url(positional[1])) { f in
      let pct = Int(f * 100)
      if last.exchange(pct) / 10 != pct / 10 { log("progress \(pct)%") }
    }
    let total = Date().timeIntervalSince(t0)
    let s = await r.lastStats
    print(String(format: "audio %.1f s | decode %.2f s, load %.2f s, inference %.2f s (RTF %.3f), write %.2f s | total %.2f s | %d chunks, %d fp32 fallbacks, %d clipped | MLX peak %.0f MiB |",
      s.audioSeconds, s.decodeSeconds, s.loadSeconds, s.inferenceSeconds, s.inferenceSeconds / s.audioSeconds,
      s.writeSeconds, total, s.chunks, s.fp32Fallbacks, s.clippedSamples, Double(s.mlxPeakBytes) / 1_048_576)
      + " " + precision.rawValue)

  default:
    fail("usage: apollo-mlx <input> <output.wav> [--weights W] [--precision fp32|fp16|bf16] | prepare | convert | parity")
  }

}

do { try await run() } catch { fail("\(error.localizedDescription)") }

final class LockedValue: @unchecked Sendable {
  private var value: Int
  private let lock = NSLock()
  init(_ v: Int) { value = v }
  func exchange(_ v: Int) -> Int { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}

// Public entry point: weights preparation and full-track repair.
//
// Verified 2026-10-05 on a MacBook Air M5 (16 GB), against apollo/ (PyTorch):
// - Parity (`apollo-mlx parity`, fixtures from tools/make_reference.py): on white noise, fp32
//   matches torch fp32 to max abs 9e-7 (119 dB SNR). On a 7 s chunk of a 64 kbps mp3, 62.8 dB
//   vs torch fp32 and 70.1 dB vs torch fp64, while torch fp32 itself is only 59.8 dB from fp64:
//   Apollo divides each band by its energy, so near-silent bands above a codec cutoff amplify
//   rounding, and no fp32 implementation gets closer. fp16 52 dB, bf16 43 dB vs torch fp32.
// - Full track, same decoded input: 71.6 dB vs Python CPU fp32. From the mp3 itself the
//   outputs differ more (27-30 dB) because AVFoundation and FFmpeg decode/resample slightly
//   differently (64 dB apart) and the model amplifies that too; neither is "the" right one.
// - Speed on a 240 s track: fp16 82 s wall (RTF 0.33, 2.7 GiB peak footprint), fp32 167 s
//   (RTF 0.69, 4.4 GiB); Python MPS on the same box: fp16 131 s / 4.4 GiB, fp32 182 s / 7.0 GiB.
// fp16 is the default: same quality metrics vs the lossless original as fp32, twice as fast.
import CryptoKit
import Foundation
import MLX

public actor ApolloMLXRepairer {
  /// Pinned upstream checkpoint (same revision and hash as apollo/'s Python bridge).
  public static let checkpointURL = URL(
    string: "https://huggingface.co/JusperLee/Apollo/resolve/c68bd80fdd9c0d93d2f4a833cb154624f660a561/pytorch_model.bin")!
  public static let checkpointSHA256 = "99d9af7f1ff20e63c393035513a655392818d66b4d7fc23d658175c1f15e8d76"
  public static let weightsFileName = "apollo-mlx.safetensors"
  public static let sampleRate = ApolloModel.sampleRate

  public static var defaultModelsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJTools/models/apollo-mlx", isDirectory: true)
  }

  public struct Options: Sendable {
    public var precision: ApolloPrecision
    public var plan: ChunkPlan
    public var outputFormat: AudioIO.WAVFormat
    /// MLX buffer-cache cap in bytes (nil leaves MLX's default).
    public var cacheLimit: Int?
    public init(precision: ApolloPrecision = .fp16, plan: ChunkPlan = ChunkPlan(),
                outputFormat: AudioIO.WAVFormat = .pcm24, cacheLimit: Int? = 512 << 20) {
      self.precision = precision
      self.plan = plan
      self.outputFormat = outputFormat
      self.cacheLimit = cacheLimit
    }
  }

  /// Timing and memory of the last repair, for benchmarking.
  public struct Stats: Sendable {
    public var audioSeconds: Double = 0
    public var decodeSeconds: Double = 0
    public var loadSeconds: Double = 0
    public var inferenceSeconds: Double = 0
    public var writeSeconds: Double = 0
    public var chunks = 0
    public var fp32Fallbacks = 0
    public var clippedSamples = 0
    public var mlxPeakBytes = 0
  }

  public let modelsDirectory: URL
  public var options: Options
  public private(set) var lastStats = Stats()
  private let explicitWeights: URL?
  private var model: ApolloModel?
  private var fallbackModel: ApolloModel?
  private var weights: [String: MLXArray]?

  /// - Parameters:
  ///   - modelsDirectory: where `prepare()` keeps the converted weights.
  ///   - weightsURL: use this converted `.safetensors` instead (prepare() then only checks it exists).
  public init(modelsDirectory: URL = ApolloMLXRepairer.defaultModelsDirectory, weightsURL: URL? = nil,
              options: Options = Options()) {
    self.modelsDirectory = modelsDirectory
    self.explicitWeights = weightsURL
    self.options = options
  }

  public var weightsURL: URL { explicitWeights ?? modelsDirectory.appendingPathComponent(Self.weightsFileName) }

  public var isPrepared: Bool { FileManager.default.fileExists(atPath: weightsURL.path) }

  public func setOptions(_ options: Options) {
    if options.precision != self.options.precision { model = nil }
    self.options = options
  }

  /// Ensures converted weights exist: downloads the pinned upstream `pytorch_model.bin`
  /// (66 MB) from Hugging Face, verifies its SHA-256, converts it to MLX safetensors in Swift
  /// (TorchCheckpoint + WeightConversion) and deletes the original. No Python involved.
  /// The result is `<modelsDirectory>/apollo-mlx.safetensors` (66 MB, fp32); its tensors are
  /// bit-identical to tools/convert_weights.py's output. About 10 s on a fast connection;
  /// a no-op once the file exists. With an explicit `weightsURL` nothing is downloaded and a
  /// missing file is an error. Cancel by cancelling the calling Task.
  public func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
    if isPrepared { progress("Weights ready"); return }
    if let explicitWeights { throw ApolloMLXError.badWeights("Weights not found at \(explicitWeights.path)") }
    let fm = FileManager.default
    try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    let checkpoint = modelsDirectory.appendingPathComponent("pytorch_model.bin")
    if !fm.fileExists(atPath: checkpoint.path) || (try? Self.sha256(checkpoint)) != Self.checkpointSHA256 {
      progress("Downloading the repair model (66 MB)")
      let (tmp, response) = try await URLSession.shared.download(from: Self.checkpointURL)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        try? fm.removeItem(at: tmp)
        throw ApolloMLXError.download("Weights download failed: HTTP \(http.statusCode)")
      }
      _ = try? fm.removeItem(at: checkpoint)
      try fm.moveItem(at: tmp, to: checkpoint)
    }
    try Task.checkCancellation()
    progress("Verifying weights")
    let digest = try Self.sha256(checkpoint)
    guard digest == Self.checkpointSHA256 else {
      try? fm.removeItem(at: checkpoint)
      throw ApolloMLXError.download("Weights checksum mismatch (\(digest))")
    }
    progress("Converting weights")
    try WeightConversion.convertCheckpoint(checkpoint, to: weightsURL)
    try? fm.removeItem(at: checkpoint)
    progress("Weights ready")
  }

  /// Deletes the converted weights (and any half-finished download) so the next prepare()
  /// fetches them again. Never touches an explicit `weightsURL`.
  public func removeWeights() throws {
    model = nil
    fallbackModel = nil
    weights = nil
    guard explicitWeights == nil else { return }
    let fm = FileManager.default
    for name in [Self.weightsFileName, "pytorch_model.bin"] {
      let url = modelsDirectory.appendingPathComponent(name)
      if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
  }

  static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func loadModel(_ precision: ApolloPrecision) throws -> ApolloModel {
    if weights == nil {
      guard isPrepared else {
        throw ApolloMLXError.badWeights("Repair model not prepared (call prepare() first)")
      }
      weights = try loadArrays(url: weightsURL)
    }
    return try ApolloModel(weights: weights!, precision: precision)
  }

  /// Repairs `input` (any format AVFoundation decodes) and writes a 44.1 kHz WAV to `output`.
  /// `progress` gets 0...1 after every chunk. Cancel by cancelling the calling Task (checked
  /// between chunks).
  @discardableResult
  public func repair(input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    if input.standardizedFileURL == output.standardizedFileURL {
      throw ApolloMLXError.audio("Input and output must be different files")
    }
    var stats = Stats()
    let clock = ContinuousClock()
    var t = clock.now
    func lap() -> Double {
      let now = clock.now
      defer { t = now }
      let d = now - t
      return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    let audio = try AudioIO.decode(input, sampleRate: Self.sampleRate)
    stats.audioSeconds = audio.duration
    stats.decodeSeconds = lap()
    try Task.checkCancellation()

    if let limit = options.cacheLimit { Memory.cacheLimit = limit }
    if model == nil || model!.precision != options.precision { model = try loadModel(options.precision) }
    stats.loadSeconds = lap()
    Memory.peakMemory = 0

    let restored = try await run(audio, stats: &stats, progress: progress)
    stats.inferenceSeconds = lap()
    stats.mlxPeakBytes = Memory.peakMemory
    stats.clippedSamples = try AudioIO.writeWAV(restored, to: output, format: options.outputFormat)
    stats.writeSeconds = lap()
    Memory.clearCache()
    lastStats = stats
    return output
  }

  /// Chunked inference over a decoded track (44.1 kHz). Both channels go through the model
  /// together as a batch of two mono rows.
  func run(_ audio: PCMAudio, stats: inout Stats, progress: @escaping @Sendable (Double) -> Void) async throws -> PCMAudio {
    let total = audio.frameCount
    let channels = audio.channels.count
    let segments = options.plan.segments(total: total)
    var out = [[Float]](repeating: [Float](repeating: 0, count: total), count: channels)
    var wsum = [Float](repeating: 0, count: total)
    progress(0)
    for (i, seg) in segments.enumerated() {
      try Task.checkCancellation()
      var rows = [Float](repeating: 0, count: channels * seg.modelLength)
      for c in 0..<channels {
        audio.channels[c].withUnsafeBufferPointer { src in
          rows.withUnsafeMutableBufferPointer { dst in
            (dst.baseAddress! + c * seg.modelLength)
              .update(from: src.baseAddress! + seg.inputStart, count: seg.inputLength)
          }
        }
      }
      let piece = try infer(MLXArray(rows, [channels, seg.modelLength]), stats: &stats)
      let kept = piece[0..., seg.keepOffset..<(seg.keepOffset + seg.outputLength)].asArray(Float.self)
      let w = segments.count == 1
        ? [Float](repeating: 1, count: seg.outputLength)
        : ChunkPlan.crossfade(length: seg.outputLength, overlap: options.plan.overlap, fadeIn: seg.fadeIn, fadeOut: seg.fadeOut)
      for c in 0..<channels {
        for j in 0..<seg.outputLength { out[c][seg.outputStart + j] += kept[c * seg.outputLength + j] * w[j] }
      }
      for j in 0..<seg.outputLength { wsum[seg.outputStart + j] += w[j] }
      stats.chunks += 1
      progress(Double(i + 1) / Double(segments.count))
      await Task.yield()
    }
    for j in 0..<total {
      guard wsum[j] > 0 else { throw ApolloMLXError.audio("Chunk overlap-add left uncovered samples") }
      for c in 0..<channels { out[c][j] /= wsum[j] }
    }
    return PCMAudio(channels: out, sampleRate: audio.sampleRate)
  }

  /// One model call; a non-finite fp16/bf16 result is redone in fp32 (as the Python bridge does).
  private func infer(_ x: MLXArray, stats: inout Stats) throws -> MLXArray {
    let y = model!(x)
    if model!.precision == .fp32 || all(isFinite(y)).item(Bool.self) { return y }
    stats.fp32Fallbacks += 1
    if fallbackModel == nil { fallbackModel = try loadModel(.fp32) }
    return fallbackModel!(x)
  }

  // MARK: - testing hooks

  /// Runs the raw model on [rows, samples] float32 and returns the output plus intermediates
  /// ("features", "layer0"... in [R*T, 80, 256] band layout). Used by the parity test.
  public func forwardForTesting(_ rows: [[Float]], capture: Set<String> = [])
    throws -> (output: [[Float]], captured: [String: (shape: [Int], values: [Float])])
  {
    if model == nil || model!.precision != options.precision { model = try loadModel(options.precision) }
    let n = rows[0].count
    let x = MLXArray(rows.flatMap { $0 }, [rows.count, n])
    var captured: [String: (shape: [Int], values: [Float])] = [:]
    let y = model!(x, capture: { name, a in
      if capture.contains(name) { captured[name] = (a.shape, a.asType(.float32).asArray(Float.self)) }
    })
    let flat = y.asType(.float32).asArray(Float.self)
    return ((0..<rows.count).map { Array(flat[($0 * n)..<(($0 + 1) * n)]) }, captured)
  }
}

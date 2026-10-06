// Tempo via Beat This! (Foscarin, Schlüter, Widmer, ISMIR 2024; https://github.com/CPJKU/beat_this,
// code and checkpoints MIT). Pipeline as upstream's inference.py with the "minimal" postprocessor:
// 22050 Hz mono -> log-mel (MelSpectrogram) -> 1500-frame chunks overlapping by 6-frame borders,
// earlier chunk wins ("keep_first") -> frame-wise beat logits -> local maxima within ±3 frames
// (max-pool 7) above logit 0 -> adjacent peaks merged -> beat times -> TempoEstimate.
// No madmom DBN (its licence is non-commercial, and upstream doesn't need it).
//
// Weights: the official final0 checkpoint (20.3 M params) as safetensors, tensor-for-tensor equal
// to cloud.cp.jku.at's final0.ckpt (checked in Python). small0 (2.1 M) gives the same BPMs on the
// test tracks but is published only on JKU's cloud, and measured no faster here: the frontend
// (identical in both) is half the per-chunk time.
//
// Verified 2026-10-06 on an M4 Pro (24 GB), against beat_this @ b95c8ab (PyTorch, CPU, fp32) on
// 15 tracks: log-mel max |Δ| ≤ 6e-4 (values up to 9) on the same 22050 Hz signal; fed the
// reference mel, fp32 logits max |Δ| ≤ 1.2e-3 and identical beats, fp16 logits ≤ 0.16 and
// beat F-measure ≥ 0.9994 (BPM within 0.05). End to end from the files (AVFoundation decode and
// resample vs soxr) F ≥ 0.990, BPM within 0.005 on electronic tracks.
// Speed for 6 minutes of audio, fp16: ~45 ms per 1500-frame chunk at full clocks (13 chunks,
// ~0.7 s total with resample and mel); 1.3–1.7 s on battery in Low Power Mode. MLX peak 243 MB.
// fp32 is about twice as slow for no BPM difference, so fp16 is the default.
import CryptoKit
import Foundation
import MLX

public enum BeatTrackerError: Error, LocalizedError {
  case badWeights(String)
  case download(String)
  case audio(String)
  case notPrepared

  public var errorDescription: String? {
    switch self {
    case .badWeights(let m), .download(let m), .audio(let m): m
    case .notPrepared: "Tempo model not downloaded (call prepare() first)"
    }
  }
}

public actor BeatTracker {
  /// Pinned Hugging Face revision of the final0 checkpoint as safetensors (MIT).
  public static let weightsURL = URL(
    string: "https://huggingface.co/safe-models/beat-this-final0/resolve/39ec64821baf38aa16fafa500a91379c16db0062/model.safetensors")!
  public static let weightsSHA256 = "f758c77ba5d862cad3718a95705964e9af55298b1fb3544c62c9d79184ea0f2e"
  public static let weightsFileName = "beat-this-final0.safetensors"

  static let chunkFrames = 1500
  static let borderFrames = 6

  public let modelsDirectory: URL
  /// Compute precision of the network; the logits come back fp32 either way.
  var dtype: DType = .float16
  private var model: BeatThisModel?
  private var verified = false

  func setPrecision(fp16: Bool) { dtype = fp16 ? .float16 : .float32 }
  /// MLX's peak allocation since the last call, in bytes (benchmarks).
  func takePeakMemory() -> Int {
    defer { Memory.peakMemory = 0 }
    return Memory.peakMemory
  }

  /// - Parameter modelsDirectory: the app passes App Support/DJTools/models/beat-this.
  public init(modelsDirectory: URL) {
    self.modelsDirectory = modelsDirectory
  }

  var weightsFile: URL { modelsDirectory.appendingPathComponent(Self.weightsFileName) }

  public var isPrepared: Bool { FileManager.default.fileExists(atPath: weightsFile.path) }

  /// Downloads the weights (81 MB) from the pinned revision if missing and verifies their
  /// SHA-256 (also when already present, once per tracker); a mismatch deletes the file and
  /// throws. Writes atomically. Cancel by cancelling the calling Task.
  public func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
    if verified && isPrepared { return }
    let fm = FileManager.default
    try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    if !isPrepared {
      progress("Downloading the tempo model (81 MB)")
      let (tmp, response) = try await URLSession.shared.download(from: Self.weightsURL)
      defer { try? fm.removeItem(at: tmp) }
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw BeatTrackerError.download("Tempo model download failed: HTTP \(http.statusCode)")
      }
      try Task.checkCancellation()
      progress("Verifying the tempo model")
      let digest = try Self.sha256(tmp)
      guard digest == Self.weightsSHA256 else {
        throw BeatTrackerError.download("Tempo model checksum mismatch (\(digest))")
      }
      let partial = modelsDirectory.appendingPathComponent(".partial-\(UUID().uuidString)")
      try fm.moveItem(at: tmp, to: partial)
      do {
        _ = try? fm.removeItem(at: weightsFile)
        try fm.moveItem(at: partial, to: weightsFile)
      } catch {
        try? fm.removeItem(at: partial)
        throw error
      }
    } else {
      progress("Verifying the tempo model")
      let digest = try Self.sha256(weightsFile)
      guard digest == Self.weightsSHA256 else {
        try? fm.removeItem(at: weightsFile)
        throw BeatTrackerError.download("Tempo model checksum mismatch (\(digest)); deleted")
      }
    }
    verified = true
    progress("Tempo model ready")
  }

  /// Deletes the weights (and any half-installed `.partial-*` copy); the next prepare()
  /// downloads them again.
  public func removeWeights() throws {
    model = nil
    verified = false
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: modelsDirectory.path)) ?? [] where name.hasPrefix(".partial-") {
      try? fm.removeItem(at: modelsDirectory.appendingPathComponent(name))
    }
    if fm.fileExists(atPath: weightsFile.path) {
      try fm.removeItem(at: weightsFile)
    }
  }

  /// Tempo of mono audio at any sample rate; nil when fewer than 8 beats are found.
  /// Needs prepared weights. Cancellable between chunks.
  public func tempo(monoSamples: [Float], sampleRate: Double) async throws -> TempoEstimate? {
    try await tempo(monoSamples: monoSamples, sampleRate: sampleRate, progress: nil)
  }

  /// Same, reporting the share of chunks done (`MusicalAnalyzer`).
  func tempo(
    monoSamples: [Float], sampleRate: Double, progress: (@Sendable (Double) -> Void)?
  ) async throws -> TempoEstimate? {
    TempoEstimate(beatTimes: try await beats(monoSamples: monoSamples, sampleRate: sampleRate, progress: progress))
  }

  /// Beat times in seconds, as upstream's minimal postprocessor reports them.
  func beats(
    monoSamples: [Float], sampleRate: Double, progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> [Double] {
    let logits = try await beatLogits(monoSamples: monoSamples, sampleRate: sampleRate, progress: progress)
    return Self.pickPeaks(logits).map { $0 / MelSpectrogram.framesPerSecond }
  }

  /// Frame-wise (50 fps) beat logits for the whole track.
  func beatLogits(
    monoSamples: [Float], sampleRate: Double, progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> [Float] {
    guard sampleRate > 0 else { throw BeatTrackerError.audio("Bad sample rate \(sampleRate)") }
    let signal = try MelSpectrogram.resample(monoSamples, from: sampleRate)
    try Task.checkCancellation()
    let (mel, frames) = MelSpectrogram.compute(signal)
    guard frames > 0 else { return [] }
    return try await logits(mel: mel, frames: frames, progress: progress)
  }

  private func loadModel() throws -> BeatThisModel {
    if let model, model.dtype == dtype { return model }
    guard isPrepared else { throw BeatTrackerError.notPrepared }
    let m = try BeatThisModel(weights: try loadArrays(url: weightsFile), dtype: dtype)
    model = m
    return m
  }

  /// Chunk starts as upstream's split_piece(avoid_short_end: true).
  static func chunkStarts(frames: Int) -> [Int] {
    let step = chunkFrames - 2 * borderFrames
    var starts = Array(stride(from: -borderFrames, to: frames - borderFrames, by: step))
    if frames > step { starts[starts.count - 1] = frames - (chunkFrames - borderFrames) }
    return starts
  }

  /// Runs the model over [frames × 128] log-mel in bordered chunks and stitches the logits.
  func logits(mel: [Float], frames: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
    let model = try loadModel()
    let bands = MelSpectrogram.bands, border = Self.borderFrames
    // Each chunk: mel[max(s,0) ..< min(s+1500, T)], zero-padded left by max(0,-s) and right by
    // max(0, min(6, s+1500-T)).
    // Each chunk's input is copied out only when it runs, so a long mix holds one at a time.
    let starts = Self.chunkStarts(frames: frames)
    func input(_ s: Int) -> (data: [Float], length: Int) {
      let lo = max(s, 0), hi = min(s + Self.chunkFrames, frames)
      let left = max(0, -s), right = max(0, min(border, s + Self.chunkFrames - frames))
      let length = left + (hi - lo) + right
      var data = [Float](repeating: 0, count: length * bands)
      data.withUnsafeMutableBufferPointer { d in
        mel.withUnsafeBufferPointer { m in
          (d.baseAddress! + left * bands).update(from: m.baseAddress! + lo * bands, count: (hi - lo) * bands)
        }
      }
      return (data, length)
    }
    // One chunk per call: batching measured no faster on the GPU and multiplies peak memory.
    var predictions: [[Float]] = []
    for s in starts {
      try Task.checkCancellation()
      let chunk = input(s)
      let out = model(MLXArray(chunk.data, [1, chunk.length, bands]))
      eval(out)
      predictions.append(out.asArray(Float.self))
      progress?(Double(predictions.count) / Double(starts.count))
      await Task.yield()
    }
    Memory.clearCache()
    // keep_first: later chunks are written first so earlier ones overwrite the overlap.
    var piece = [Float](repeating: -1000, count: frames)
    for c in starts.indices.reversed() {
      let kept = predictions[c].dropFirst(border).dropLast(border)
      var t = starts[c] + border
      for v in kept {
        if t >= 0 && t < frames { piece[t] = v }
        t += 1
      }
    }
    return piece
  }

  /// Upstream's minimal postprocessing: frames that equal the max over ±3 frames and have a
  /// positive logit, with runs of adjacent peak frames replaced by their mean. Fractional frames.
  static func pickPeaks(_ logits: [Float]) -> [Double] {
    let n = logits.count
    var peaks: [Int] = []
    for t in 0..<n where logits[t] > 0 {
      var isMax = true
      for u in max(0, t - 3)...min(n - 1, t + 3) where logits[u] > logits[t] { isMax = false; break }
      if isMax { peaks.append(t) }
    }
    var result: [Double] = []
    guard var p = peaks.first.map(Double.init) else { return result }
    var count = 1.0
    for q in peaks.dropFirst() {
      if Double(q) - p <= 1 {
        count += 1
        p += (Double(q) - p) / count
      } else {
        result.append(p)
        p = Double(q)
        count = 1
      }
    }
    result.append(p)
    return result
  }

  static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

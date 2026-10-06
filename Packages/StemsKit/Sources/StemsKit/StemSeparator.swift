@preconcurrency import AVFoundation
import DemucsAudio
import DemucsMLX
import Foundation
import MLX

/// Demucs model variants offered by the app. All three are published by
/// demucs-mlx-swift (weights from Hugging Face `ssmall256/demucs-mlx`).
public enum StemModel: String, Sendable, CaseIterable {
  /// Hybrid Transformer Demucs, 4 stems, ~160 MB. Fast default.
  case htdemucs
  /// Fine-tuned ensemble of four htdemucs models, 4 stems, ~640 MB, ~4x slower, slightly cleaner.
  case htdemucsFT
  /// 6-stem htdemucs (adds guitar and piano), ~105 MB. "piano"/"other" are noticeably weaker.
  case htdemucs6s

  /// Stem names this model writes, in model order.
  public var stemNames: [String] {
    switch self {
    case .htdemucs, .htdemucsFT: ["drums", "bass", "other", "vocals"]
    case .htdemucs6s: ["drums", "bass", "other", "vocals", "guitar", "piano"]
    }
  }

  public var displayName: String {
    switch self {
    case .htdemucs: "HT Demucs"
    case .htdemucsFT: "HT Demucs (fine-tuned)"
    case .htdemucs6s: "HT Demucs 6-stem"
    }
  }

  /// Approximate download size of the weights in bytes.
  public var downloadSize: Int64 { ModelHub.downloadSize(of: demucs) }

  /// Accepts the enum raw value (`htdemucsFT`) or the upstream Demucs name (`htdemucs_ft`).
  public init?(name: String) {
    if let model = StemModel(rawValue: name) {
      self = model
    } else if let model = StemModel.allCases.first(where: { $0.demucs.rawValue == name }) {
      self = model
    } else {
      return nil
    }
  }

  var demucs: DemucsModel {
    switch self {
    case .htdemucs: .htdemucs
    case .htdemucsFT: .htdemucsFT
    case .htdemucs6s: .htdemucs6s
    }
  }
}

/// Stem name ("vocals", "drums", "bass", "other", and for 6s "guitar", "piano") → written WAV.
public struct StemResult: Sendable {
  public var stems: [String: URL]
  public init(stems: [String: URL]) { self.stems = stems }
}

public enum StemsError: Error, LocalizedError, Sendable {
  case inputNotFound(URL)
  case unreadableInput(URL, String)

  public var errorDescription: String? {
    switch self {
    case .inputNotFound(let url): "File not found: \(url.path)"
    case .unreadableInput(let url, let why): "Can't read \(url.lastPathComponent): \(why)"
    }
  }
}

/// Separates a track into stems. Keep one instance per model and reuse it: the loaded
/// weights and compiled graphs stay in memory between calls. Inference runs one call at a time.
public actor StemSeparator {
  /// `~/Library/Application Support/DJTools/models/`
  public static var defaultModelsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJTools", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }

  public nonisolated let model: StemModel
  /// Where weights are cached (`<model>.safetensors` + `<model>_config.json`).
  public nonisolated let modelsDirectory: URL
  private var separator: Separator?

  public init(
    model: StemModel = .htdemucs, modelsDirectory: URL = StemSeparator.defaultModelsDirectory
  ) {
    self.model = model
    self.modelsDirectory = modelsDirectory
  }

  /// True when the weights are already on disk (no download needed on first `separate`).
  public nonisolated var isModelDownloaded: Bool {
    ModelHub.isCached(model.demucs, in: modelsDirectory)
  }

  /// Writes `<outputDirectory>/<track name> (Stems)/<stem>.wav` (24-bit PCM, at the
  /// input's sample rate), replacing an existing folder of that name. Downloads the
  /// weights first if needed. `progress` goes 0…1 and is called from background
  /// executors. Cancel the calling task to stop; no partial stem folder is left behind.
  public func separate(
    input: URL, outputDirectory: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> StemResult {
    // MLX keeps freed GPU buffers cached; hand them back once a job ends, however it ends.
    // (Only once MLX is up: touching it earlier loads the metallib for nothing.)
    defer { if separator != nil { Memory.clearCache() } }
    let reporter = ProgressReporter(progress)
    reporter.report(0)
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: input.path) else {
      throw StemsError.inputNotFound(input)
    }
    let source = try SourceInfo(input)

    // Phase weights: [download] → load+decode → inference → export.
    let downloadSpan = isModelDownloaded || separator != nil ? 0.0 : 0.25
    let rest = 1 - downloadSpan
    let decodeEnd = downloadSpan + rest * 0.05
    let inferenceEnd = downloadSpan + rest * 0.90

    let separator = try await loadSeparator { fraction in
      reporter.report(fraction * downloadSpan)
    }
    reporter.report(downloadSpan + rest * 0.02)

    let result = try await DemucsAudio.separate(input, using: separator) { p in
      reporter.report(decodeEnd + p.fractionCompleted * (inferenceEnd - decodeEnd))
    }
    try Task.checkCancellation()

    // Export into a hidden staging folder, then move it into place.
    let fm = FileManager.default
    try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let trackName = input.deletingPathExtension().lastPathComponent
    let finalDirectory = outputDirectory.appendingPathComponent(
      "\(trackName) (Stems)", isDirectory: true)
    let staging = outputDirectory.appendingPathComponent(
      ".\(trackName) (Stems).\(UUID().uuidString).partial", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    var keepStaging = false
    defer { if !keepStaging { try? fm.removeItem(at: staging) } }

    var written: [String: URL] = [:]
    for (index, name) in result.sources.enumerated() {
      try Task.checkCancellation()
      var audio = result.audio[index]
      if source.sampleRate != result.sampleRate {
        audio = try Self.resample(
          audio, from: result.sampleRate, to: source.sampleRate, frames: source.frames)
      }
      let file = staging.appendingPathComponent("\(name).wav")
      try DemucsAudio.save(audio, sampleRate: source.sampleRate, to: file, format: .wav(.pcm24))
      written[name] = finalDirectory.appendingPathComponent("\(name).wav")
      reporter.report(
        inferenceEnd + (1 - inferenceEnd) * Double(index + 1) / Double(result.sources.count))
    }
    try Task.checkCancellation()

    if fm.fileExists(atPath: finalDirectory.path) {
      try fm.removeItem(at: finalDirectory)
    }
    try fm.moveItem(at: staging, to: finalDirectory)
    keepStaging = true
    reporter.report(1)
    return StemResult(stems: written)
  }

  /// Fetch the weights ahead of time (e.g. from a settings screen). `progress` is 0…1.
  public func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
    guard !isModelDownloaded else {
      progress(1)
      return
    }
    try await ModelHub.download(model.demucs, to: modelsDirectory) { progress($0.fractionCompleted) }
    progress(1)
  }

  private func loadSeparator(
    downloadProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> Separator {
    if let separator { return separator }
    try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    let loaded = try await Separator.load(
      model: model.demucs, cacheDirectory: modelsDirectory,
      options: Self.options, download: .ifMissing
    ) { downloadProgress($0.fractionCompleted) }
    // Another call may have loaded one while we were suspended; keep the first.
    if let separator { return separator }
    separator = loaded
    return loaded
  }

  private static var options: SeparationOptions {
    var options = SeparationOptions()
    // Upstream picks batch 2 on small Macs. On a 16 GB M5 Air batch 1 was as fast
    // (14.3 s vs 15.1 s warm for a 5:36 track) with ~2 GB less peak memory (6.1 vs 8.1 GB).
    if ProcessInfo.processInfo.physicalMemory <= 24 * 1_073_741_824 {
      options.batchSize = 1
    }
    return options
  }

  /// Resample a `[channels, samples]` stem back to the source rate and match its length.
  private static func resample(_ audio: MLXArray, from: Int, to: Int, frames: Int) throws
    -> MLXArray
  {
    let buffer = try DemucsAudio.pcmBuffer(from: audio, sampleRate: from)
    var out = try DemucsAudio.tensor(from: buffer, sampleRate: to)
    let length = out.dim(1)
    if length > frames {
      out = out[0..., 0 ..< frames]
    } else if length < frames {
      out = concatenated([out, MLXArray.zeros([out.dim(0), frames - length])], axis: 1)
    }
    return out
  }
}

private struct SourceInfo {
  let sampleRate: Int
  let frames: Int

  init(_ url: URL) throws {
    do {
      let file = try AVAudioFile(forReading: url)
      sampleRate = Int(file.fileFormat.sampleRate.rounded())
      frames = Int(file.length)
    } catch {
      throw StemsError.unreadableInput(url, error.localizedDescription)
    }
    guard sampleRate > 0, frames > 1 else {
      throw StemsError.unreadableInput(url, "no audio")
    }
  }
}

/// Clamps to 0…1 and never goes backwards.
private final class ProgressReporter: @unchecked Sendable {
  private let lock = NSLock()
  private var last = -1.0
  private let sink: @Sendable (Double) -> Void

  init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

  func report(_ value: Double) {
    let clamped = min(1, max(0, value))
    let send = lock.withLock { () -> Bool in
      guard clamped > last + 0.0005 || (clamped == 1 && last < 1) || last < 0 else { return false }
      last = clamped
      return true
    }
    if send { sink(clamped) }
  }
}

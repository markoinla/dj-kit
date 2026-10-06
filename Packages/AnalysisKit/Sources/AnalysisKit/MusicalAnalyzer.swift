// BPM and key of a file: one decode to mono at the file's rate, then libkeyfinder (CPU) and
// Beat This! (GPU, resampling to 22050 Hz itself) side by side on the same samples.
import Accelerate
import AVFoundation
import Foundation

public struct MusicalAnalysis: Sendable, Codable, Equatable {
  /// Nil: no beats found.
  public var tempo: TempoEstimate?
  /// Nil: silent or atonal.
  public var key: KeyEstimate?
  public var duration: TimeInterval

  public init(tempo: TempoEstimate?, key: KeyEstimate?, duration: TimeInterval) {
    self.tempo = tempo
    self.key = key
    self.duration = duration
  }
}

public enum MusicalAnalyzerError: Error, LocalizedError {
  case unreadable(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let m): m
    }
  }
}

public actor MusicalAnalyzer {
  private let tracker: BeatTracker
  /// The one download or check in flight, shared by concurrent analyses.
  private var preparing: Task<Void, any Error>?

  /// - Parameter modelsDirectory: the app passes App Support/DJTools/models/beat-this.
  public init(modelsDirectory: URL) {
    tracker = BeatTracker(modelsDirectory: modelsDirectory)
  }

  /// The tempo model's weights are on disk.
  public var isPrepared: Bool {
    get async { await tracker.isPrepared }
  }

  /// Decodes `url` (anything AVAudioFile reads: MP3, M4A, FLAC, WAV, AIFF) once, then detects the
  /// key and the tempo concurrently. The first call downloads the tempo model (81 MB) when it's
  /// missing and checks it. Safe to call concurrently; cancel by cancelling the calling Task.
  ///
  /// - Parameters:
  ///   - progress: 0…1 (decode, then the network's chunks).
  ///   - status: "Downloading model…" or "Verifying model…" while the model is set up, then
  ///     "Analyzing…".
  public nonisolated func analyze(
    _ url: URL,
    progress: (@Sendable (Double) -> Void)? = nil,
    status: (@Sendable (String) -> Void)? = nil
  ) async throws -> MusicalAnalysis {
    try await prepare(status: status)
    try Task.checkCancellation()
    status?("Analyzing…")
    progress?(0)
    let decodeShare = 0.4
    let audio = try Self.decodeMono(url) { progress?(decodeShare * $0) }
    try Task.checkCancellation()
    let samples = audio.samples, rate = audio.rate
    let duration = rate > 0 ? Double(samples.count) / rate : 0
    guard !samples.isEmpty else {
      progress?(1)
      return MusicalAnalysis(tempo: nil, key: nil, duration: duration)
    }
    async let key = KeyDetector.detect(monoSamples: samples, sampleRate: rate)
    let tempo = try await tracker.tempo(monoSamples: samples, sampleRate: rate) { fraction in
      progress?(decodeShare + (1 - decodeShare) * fraction)
    }
    let analysis = MusicalAnalysis(tempo: tempo, key: await key, duration: duration)
    progress?(1)
    return analysis
  }

  /// Deletes the tempo model; the next analysis downloads it again.
  public func removeWeights() async throws {
    preparing?.cancel()
    preparing = nil
    try await tracker.removeWeights()
  }

  private func prepare(status: (@Sendable (String) -> Void)?) async throws {
    let tracker = self.tracker
    if preparing == nil {
      preparing = Task {
        try await tracker.prepare { line in
          if line.hasPrefix("Downloading") { status?("Downloading model…") }
          if line.hasPrefix("Verifying") { status?("Verifying model…") }
        }
      }
    } else if !(await tracker.isPrepared) {
      status?("Downloading model…")
    }
    guard let task = preparing else { return }
    do {
      try await task.value
    } catch {
      // A failed or cancelled setup is tried again on the next call.
      if preparing == task { preparing = nil }
      throw error
    }
  }

  /// The whole file averaged to mono, at its own rate.
  static func decodeMono(_ url: URL, progress: (Double) -> Void) throws -> (samples: [Float], rate: Double) {
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      throw MusicalAnalyzerError.unreadable("Can't read the audio: \(error.localizedDescription)")
    }
    let format = file.processingFormat
    let channels = Int(format.channelCount), total = Int(file.length)
    guard channels > 0, total > 0 else { return ([], format.sampleRate) }
    let chunk: AVAudioFrameCount = 1 << 16
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
      throw MusicalAnalyzerError.unreadable("Can't read the audio: out of memory")
    }
    var mono: [Float] = []
    mono.reserveCapacity(total)
    var reported = 0.0
    while file.framePosition < file.length {
      try Task.checkCancellation()
      do {
        try file.read(into: buffer, frameCount: chunk)
      } catch {
        throw MusicalAnalyzerError.unreadable("Can't read the audio: \(error.localizedDescription)")
      }
      let n = Int(buffer.frameLength)
      if n == 0 { break }
      let data = buffer.floatChannelData!
      let start = mono.count
      mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
      if channels > 1 {
        mono.withUnsafeMutableBufferPointer { m in
          let out = m.baseAddress! + start
          for c in 1..<channels { vDSP_vadd(out, 1, data[c], 1, out, 1, vDSP_Length(n)) }
          var scale = 1 / Float(channels)
          vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(n))
        }
      }
      let fraction = min(Double(mono.count) / Double(total), 1)
      if fraction - reported >= 0.01 {
        reported = fraction
        progress(fraction)
      }
    }
    return (mono, format.sampleRate)
  }
}

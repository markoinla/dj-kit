// BPM and key of a file: one streaming decode to 22050 Hz mono (what Beat This! takes, so the
// tracker doesn't resample; libkeyfinder decimates to ~4.4 kHz itself and gives the same keys),
// then libkeyfinder (CPU) and Beat This! (GPU) side by side on the same samples. A 2-hour mix is
// ~635 MB of samples instead of 1.27 GB at 44.1 kHz plus a resampled copy.
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
  /// The file: worth remembering per track.
  case unreadable(String)
  /// The tempo model couldn't be downloaded or checked (offline, server error): transient, the
  /// next call tries again.
  case modelUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let m), .modelUnavailable(let m): m
    }
  }
}

public actor MusicalAnalyzer {
  private let tracker: BeatTracker
  /// The one download or check in flight (or done), shared by concurrent analyses, and which
  /// one it is (`waiters` is per setup).
  private var preparing: Task<Void, any Error>?
  private var generation = 0
  private var prepared = false
  /// Callers awaiting each setup; the last one to give up cancels it.
  private var waiters: [Int: Int] = [:]
  /// The last setup failure: for `retryCooldown` after it, calls fail fast with its message
  /// instead of waiting on a hung server or downloading 81 MB again.
  private var lastFailure: (date: Date, message: String)?
  /// After a failed setup, how long calls fail fast (unless `retryingModel`).
  var retryCooldown: TimeInterval = 120
  /// Setups started (tests).
  private(set) var setupAttempts = 0

  func setRetryCooldown(_ seconds: TimeInterval) { retryCooldown = seconds }

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
  /// missing and checks it; failing that throws `.modelUnavailable`, and so does every call for
  /// two minutes after, straight away. Safe to call concurrently; cancel by cancelling the calling
  /// Task (also while the model downloads).
  ///
  /// - Parameters:
  ///   - retryingModel: try the setup again even within two minutes of a failure (Try Again).
  ///   - progress: 0…1 (decode, then the network's chunks).
  ///   - status: "Downloading model…" or "Verifying model…" while the model is set up, then
  ///     "Analyzing…".
  public nonisolated func analyze(
    _ url: URL,
    retryingModel: Bool = false,
    progress: (@Sendable (Double) -> Void)? = nil,
    status: (@Sendable (String) -> Void)? = nil
  ) async throws -> MusicalAnalysis {
    try await prepare(retrying: retryingModel, status: status)
    try Task.checkCancellation()
    status?("Analyzing…")
    progress?(0)
    let decodeShare = 0.4
    let rate = MelSpectrogram.sampleRate
    let samples = try Self.decodeMono(url, rate: rate) { progress?(decodeShare * $0) }
    try Task.checkCancellation()
    let duration = Double(samples.count) / rate
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
    prepared = false
    lastFailure = nil
    try await tracker.removeWeights()
  }

  private func prepare(retrying: Bool, status: (@Sendable (String) -> Void)?) async throws {
    let tracker = self.tracker
    let onDisk = await tracker.isPrepared
    // Set up once; again when an earlier setup failed, or the weights went missing since.
    if preparing == nil || (prepared && !onDisk) {
      if !retrying, let failure = lastFailure, Date().timeIntervalSince(failure.date) < retryCooldown {
        throw MusicalAnalyzerError.modelUnavailable(failure.message)
      }
      prepared = false
      generation += 1
      setupAttempts += 1
      preparing = Task {
        try await tracker.prepare { line in
          if line.hasPrefix("Downloading") { status?("Downloading model…") }
          if line.hasPrefix("Verifying") { status?("Verifying model…") }
        }
      }
    } else if !prepared && !onDisk {
      status?("Downloading model…")
    }
    guard let task = preparing else { return }
    let mine = generation
    waiters[mine, default: 0] += 1
    func leave() -> Int {
      let left = (waiters[mine] ?? 1) - 1
      waiters[mine] = left > 0 ? left : nil
      return left
    }
    do {
      try await Self.value(of: task)
      _ = leave()
      if preparing == task {
        prepared = true
        lastFailure = nil
      }
    } catch is CancellationError {
      // The shared setup keeps going for the others; the last caller to leave stops it.
      if leave() == 0, preparing == task, !prepared {
        task.cancel()
        preparing = nil
      }
      throw CancellationError()
    } catch {
      _ = leave()
      // A failed setup is tried again on the next call after the cooldown.
      let message = error.localizedDescription
      if preparing == task {
        preparing = nil
        lastFailure = (Date(), message)
      }
      throw MusicalAnalyzerError.modelUnavailable(message)
    }
  }

  /// `task.value`, but a cancelled caller returns straight away (CancellationError) instead of
  /// waiting for a task it doesn't own.
  private static func value(of task: Task<Void, any Error>) async throws {
    let once = ResumeOnce()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        once.install(continuation)
        Task {
          do {
            try await task.value
            once.finish(.success(()))
          } catch {
            once.finish(.failure(error))
          }
        }
      }
    } onCancel: {
      once.finish(.failure(CancellationError()))
    }
  }

  /// The whole file averaged to mono and resampled to `rate` as it's read (Core Audio's
  /// mastering-quality converter, as `BeatTracker` resamples), so no full-rate copy is kept.
  static func decodeMono(_ url: URL, rate: Double, progress: @escaping (Double) -> Void) throws -> [Float] {
    let reader = try MonoReader(url, progress: progress)
    let fileRate = reader.mono.format.sampleRate
    guard reader.total > 0 else { return [] }
    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(reader.total) * rate / fileRate) + 1)
    if fileRate == rate {
      while reader.next() {
        samples.append(contentsOf: UnsafeBufferPointer(
          start: reader.mono.floatChannelData![0], count: Int(reader.mono.frameLength)))
      }
      try reader.check()
      return samples
    }

    guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let converter = AVAudioConverter(from: reader.mono.format, to: outFormat),
      let out = AVAudioPCMBuffer(
        pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(MonoReader.chunk) * rate / fileRate) + 1024)
    else { throw MusicalAnalyzerError.unreadable("Can't resample from \(fileRate) Hz") }
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    while true {
      var error: NSError?
      let status = converter.convert(to: out, error: &error) { _, outStatus in
        guard reader.next() else {
          outStatus.pointee = .endOfStream
          return nil
        }
        outStatus.pointee = .haveData
        return reader.mono
      }
      if status == .error {
        throw MusicalAnalyzerError.unreadable("Can't resample: \(error?.localizedDescription ?? "?")")
      }
      samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
      try reader.check()
      if status == .endOfStream || (reader.ended && out.frameLength == 0) { break }
    }
    // The converter's tail can run a few frames past the exact length.
    let expected = Int((Double(reader.framesRead) * rate / fileRate).rounded())
    if samples.count > expected { samples.removeLast(samples.count - expected) }
    return samples
  }
}

/// Reads a file chunk by chunk, averaged to mono at its own rate. Used from one thread at a time
/// (the converter calls back synchronously).
private final class MonoReader: @unchecked Sendable {
  static let chunk: AVAudioFrameCount = 1 << 16
  let file: AVAudioFile
  let read: AVAudioPCMBuffer
  /// The latest chunk.
  let mono: AVAudioPCMBuffer
  let total: Int
  private let progress: (Double) -> Void
  private(set) var framesRead = 0
  private(set) var ended = false
  private var error: (any Error)?
  private var reported = 0.0

  init(_ url: URL, progress: @escaping (Double) -> Void) throws {
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      throw MusicalAnalyzerError.unreadable("Can't read the audio: \(error.localizedDescription)")
    }
    let format = file.processingFormat
    guard format.channelCount > 0,
      let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunk),
      let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.chunk)
    else { throw MusicalAnalyzerError.unreadable("Can't read the audio: unsupported format") }
    self.read = read
    self.mono = mono
    total = Int(file.length)
    self.progress = progress
  }

  /// The next chunk into `mono`; false at the end, on an error or when the task is cancelled.
  func next() -> Bool {
    if ended { return false }
    guard !Task.isCancelled, file.framePosition < file.length else { ended = true; return false }
    do {
      try file.read(into: read, frameCount: Self.chunk)
    } catch {
      self.error = error
      ended = true
      return false
    }
    let n = Int(read.frameLength), channels = Int(read.format.channelCount)
    guard n > 0 else { ended = true; return false }
    let data = read.floatChannelData!, out = mono.floatChannelData![0]
    out.update(from: data[0], count: n)
    if channels > 1 {
      for c in 1..<channels { vDSP_vadd(out, 1, data[c], 1, out, 1, vDSP_Length(n)) }
      var scale = 1 / Float(channels)
      vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(n))
    }
    mono.frameLength = AVAudioFrameCount(n)
    framesRead += n
    let fraction = min(Double(framesRead) / Double(max(total, 1)), 1)
    if fraction - reported >= 0.01 {
      reported = fraction
      progress(fraction)
    }
    return true
  }

  /// Throws for cancellation or a read error.
  func check() throws {
    try Task.checkCancellation()
    if let error { throw MusicalAnalyzerError.unreadable("Can't read the audio: \(error.localizedDescription)") }
  }
}

/// Resumes a continuation once, whichever comes first: the result or the caller's cancellation.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  func install(_ c: CheckedContinuation<Void, any Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      c.resume(with: result)
    } else {
      continuation = c
      lock.unlock()
    }
  }

  func finish(_ r: Result<Void, any Error>) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = r
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(with: r)
  }
}

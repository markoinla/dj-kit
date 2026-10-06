// MusicalAnalyzer end to end on a written file. Needs the Beat This! weights (see
// TempoModelTests.swift for where they come from); run with xcodebuild.
import AVFoundation
import Foundation
import Testing
@testable import AnalysisKit

@Suite(.enabled(if: TempoTestEnv.hasWeights, "Beat This! weights not available"), .serialized)
struct MusicalAnalyzerTests {
  /// A 128 BPM drum loop over a held A minor triad, stereo 44.1 kHz WAV.
  static func writeLoop(seconds: Double) throws -> URL {
    let rate = 44_100.0
    var mono = TempoTestEnv.drumLoop(bpm: 128, seconds: seconds, rate: rate)
    for (i, _) in mono.enumerated() {
      let t = Double(i) / rate
      let chord = [220.0, 261.63, 329.63].reduce(0) { $0 + sin(2 * .pi * $1 * t) } * 0.12
      mono[i] += Float(chord)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("analyzer-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count))!
    buffer.frameLength = AVAudioFrameCount(mono.count)
    for c in 0..<2 { mono.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: mono.count) } }
    try file.write(from: buffer)
    return url
  }

  @Test func analyzesAFile() async throws {
    let url = try Self.writeLoop(seconds: 60)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: TempoTestEnv.modelsDirectory)
    let fractions = Recorder<Double>(), lines = Recorder<String>()
    let a = try await analyzer.analyze(url, progress: { fractions.add($0) }, status: { lines.add($0) })
    let tempo = try #require(a.tempo)
    #expect(abs(tempo.bpm(in: BPMRange.standard) - 128) <= 0.5)
    #expect(tempo.isSteady)
    #expect(a.key?.key == MusicalKey(tonic: 9, isMinor: true))
    #expect(abs(a.duration - 60) < 0.01)
    let p = fractions.values
    #expect(p.first == 0 && p.last == 1)
    #expect(zip(p, p.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(lines.values.last == "Analyzing…")
  }

  @Test func concurrentAnalysesAgree() async throws {
    let url = try Self.writeLoop(seconds: 30)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: TempoTestEnv.modelsDirectory)
    async let a = analyzer.analyze(url)
    async let b = analyzer.analyze(url)
    let (x, y) = try await (a, b)
    #expect(x == y)
  }

  @Test func unreadableFileThrows() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: TempoTestEnv.modelsDirectory)
    await #expect(throws: MusicalAnalyzerError.self) { try await analyzer.analyze(url) }
  }

  /// No models folder can be made: a transient `.modelUnavailable`, not a file error.
  @Test func modelSetupFailureIsTransient() async throws {
    let url = try Self.writeLoop(seconds: 5)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: URL(fileURLWithPath: "/dev/null/beat-this"))
    do {
      _ = try await analyzer.analyze(url)
      Issue.record("expected modelUnavailable")
    } catch MusicalAnalyzerError.modelUnavailable {
    } catch {
      Issue.record("\(error)")
    }
  }

  /// After a failed setup, calls fail fast for the cooldown (no second attempt) unless retrying.
  @Test func failedSetupCoolsDown() async throws {
    let url = try Self.writeLoop(seconds: 5)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: URL(fileURLWithPath: "/dev/null/beat-this"))
    for _ in 0..<3 {
      await #expect(throws: MusicalAnalyzerError.self) { try await analyzer.analyze(url) }
    }
    #expect(await analyzer.setupAttempts == 1)
    await #expect(throws: MusicalAnalyzerError.self) { try await analyzer.analyze(url, retryingModel: true) }
    #expect(await analyzer.setupAttempts == 2)
    await analyzer.setRetryCooldown(0)
    await #expect(throws: MusicalAnalyzerError.self) { try await analyzer.analyze(url) }
    #expect(await analyzer.setupAttempts == 3)
  }

  /// The streaming 22050 Hz decode feeds the tracker the same beats as the Python reference
  /// (BEAT_THIS_REF_DIR + BEAT_THIS_AUDIO), and libkeyfinder gives the same keys as at the file's rate.
  @Test(.enabled(if: TempoTestEnv.refDir != nil && TempoTestEnv.audioDir != nil))
  func streamingDecodeMatchesReference() async throws {
    let ref = try #require(TempoTestEnv.refDir), audio = try #require(TempoTestEnv.audioDir)
    let tracker = try await TempoTestEnv.tracker()
    let files = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
    var compared = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let name = file.deletingPathExtension().lastPathComponent
      let refBeatsURL = ref.appendingPathComponent(name).appendingPathComponent("beats_final0.txt")
      guard FileManager.default.fileExists(atPath: refBeatsURL.path) else { continue }
      let refBeats = try TempoTestEnv.readBeats(refBeatsURL)
      let samples = try MusicalAnalyzer.decodeMono(file, rate: 22_050) { _ in }
      let beats = try await tracker.beats(monoSamples: samples, sampleRate: 22_050)
      let (f, _) = TempoTestEnv.fMeasure(reference: refBeats, estimate: beats)
      let e = TempoEstimate(beatTimes: beats), r = TempoEstimate(beatTimes: refBeats)
      let native = try TempoTestEnv.decodeMono(file)
      let keyNative = KeyDetector.detect(monoSamples: native.samples, sampleRate: native.rate)?.key
      let key22 = KeyDetector.detect(monoSamples: samples, sampleRate: 22_050)?.key
      print(String(format: "stream %@: F %.4f, BPM %.3f vs %.3f, key %@ vs %@ (native)", name, f,
                   e?.rawBPM ?? 0, r?.rawBPM ?? 0, key22?.camelot ?? "-", keyNative?.camelot ?? "-"))
      #expect(f > 0.97, "\(name)")
      #expect(abs((e?.rawBPM ?? 0) - (r?.rawBPM ?? 0)) < 0.1, "\(name)")
      #expect(key22 == keyNative, "\(name)")
      compared += 1
    }
    #expect(compared > 0)
  }

  @Test func cancellation() async throws {
    let url = try Self.writeLoop(seconds: 120)
    defer { try? FileManager.default.removeItem(at: url) }
    let analyzer = MusicalAnalyzer(modelsDirectory: TempoTestEnv.modelsDirectory)
    let task = Task { try await analyzer.analyze(url) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

/// Collects callback values from any thread.
final class Recorder<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [T] = []
  func add(_ value: T) { lock.withLock { items.append(value) } }
  var values: [T] { lock.withLock { items } }
}

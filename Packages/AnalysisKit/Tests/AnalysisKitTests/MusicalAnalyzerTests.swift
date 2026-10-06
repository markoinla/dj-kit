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

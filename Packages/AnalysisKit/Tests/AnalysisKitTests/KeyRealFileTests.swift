import AVFoundation
import Foundation
import Testing
@testable import AnalysisKit

/// Prints key, margin and timing for the FLACs in testdata/ (or $DJT_TESTDATA).
/// Skipped when there are none; audio isn't committed. Time it with
/// `swift test -c release -Xswiftc -enable-testing --filter KeyRealFile`.
@Suite struct KeyRealFileTests {
  static let folder: URL = {
    if let path = ProcessInfo.processInfo.environment["DJT_TESTDATA"] {
      return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../testdata").standardized
  }()

  static let files: [URL] =
    ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "flac" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  /// Whole file averaged to mono.
  static func mono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let n = Int(buffer.frameLength)
    var mix = [Float](repeating: 0, count: n)
    for c in 0..<Int(format.channelCount) {
      let channel = buffer.floatChannelData![c]
      for i in 0..<n { mix[i] += channel[i] / Float(format.channelCount) }
    }
    return (mix, format.sampleRate)
  }

  /// Mono resampled with AVAudioConverter.
  static func resample(_ samples: [Float], from rate: Double, to target: Double) throws -> [Float] {
    let source = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: target, channels: 1))
    nonisolated(unsafe) let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)))
    input.frameLength = input.frameCapacity
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let capacity = AVAudioFrameCount(Double(samples.count) * target / rate) + 4096
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
    let converter = try #require(AVAudioConverter(from: source, to: format))
    nonisolated(unsafe) var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      status.pointee = fed ? .endOfStream : .haveData
      defer { fed = true }
      return fed ? nil : input
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
  }

  static func timed<T>(_ body: () -> T) -> (T, Double) {
    let start = ContinuousClock.now
    let value = body()
    let elapsed = ContinuousClock.now - start
    return (value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
  }

  @Test(.enabled(if: !files.isEmpty)) func realFiles() throws {
    for url in Self.files {
      let (samples, rate) = try Self.mono(url)
      let (native, nativeTime) = Self.timed { KeyDetector.detect(monoSamples: samples, sampleRate: rate) }
      let small = try Self.resample(samples, from: rate, to: 22_050)
      let (low, lowTime) = Self.timed { KeyDetector.detect(monoSamples: small, sampleRate: 22_050) }
      let line = [
        url.deletingPathExtension().lastPathComponent,
        String(format: "%.0fs", Double(samples.count) / rate),
        native.map { "\($0.key.camelot) \($0.key.musical) m=\(String(format: "%.4f", $0.margin))" } ?? "nil",
        String(format: "%.3fs @%.0f", nativeTime, rate),
        low.map { "22k: \($0.key.camelot) m=\(String(format: "%.4f", $0.margin))" } ?? "22k: nil",
        String(format: "%.3fs", lowTime),
      ].joined(separator: " | ")
      print("KEY", line)
      #expect(native != nil)
    }
  }
}

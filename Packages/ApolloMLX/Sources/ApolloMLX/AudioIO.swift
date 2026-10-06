// Audio decode (AVFoundation: mp3, m4a/aac/alac, flac, wav, aiff, caf) with resampling to
// 44.1 kHz, and a small WAV writer (24-bit PCM or 32-bit float).
import AVFoundation
import Foundation

public struct PCMAudio: Sendable {
  /// One array per channel (1 or 2), float32.
  public var channels: [[Float]]
  public var sampleRate: Int
  public var frameCount: Int { channels.first?.count ?? 0 }
  public var duration: Double { Double(frameCount) / Double(sampleRate) }
}

private final class UncheckedBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

public enum AudioIO {
  /// Decode `url` to float32 at `sampleRate`. Mono stays mono; more than two channels keep
  /// the first two (front L/R).
  public static func decode(_ url: URL, sampleRate: Int = 44_100) throws -> PCMAudio {
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
      throw ApolloMLXError.audio("Can't open \(url.lastPathComponent): \(error.localizedDescription)")
    }
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    guard channelCount > 0 else { throw ApolloMLXError.audio("No audio channels in \(url.lastPathComponent)") }
    let keep = min(channelCount, 2)

    // Read the whole file (file.length can be an estimate for mp3, so read until empty).
    var source = [[Float]](repeating: [], count: keep)
    let block: AVAudioFrameCount = 1 << 18
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
      throw ApolloMLXError.audio("Can't allocate audio buffer")
    }
    for c in 0..<keep { source[c].reserveCapacity(Int(file.length)) }
    while true {
      do { try file.read(into: buffer, frameCount: block) } catch {
        if buffer.frameLength == 0 { break }
        throw ApolloMLXError.audio("Decode failed: \(error.localizedDescription)")
      }
      let n = Int(buffer.frameLength)
      if n == 0 { break }
      for c in 0..<keep {
        source[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: n))
      }
    }
    guard (source.first?.count ?? 0) > 0 else { throw ApolloMLXError.audio("No audio samples in \(url.lastPathComponent)") }
    let inRate = Int(format.sampleRate.rounded())
    var audio = PCMAudio(channels: source, sampleRate: inRate)
    if inRate != sampleRate { audio = try resample(audio, to: sampleRate) }
    for c in audio.channels.indices {
      for i in audio.channels[c].indices where !audio.channels[c][i].isFinite { audio.channels[c][i] = 0 }
    }
    return audio
  }

  /// Band-limited resampling with AVAudioConverter (mastering algorithm, max quality).
  public static func resample(_ audio: PCMAudio, to rate: Int) throws -> PCMAudio {
    let ch = AVAudioChannelCount(audio.channels.count)
    guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: ch, interleaved: false),
      let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: ch, interleaved: false),
      let converter = AVAudioConverter(from: inFormat, to: outFormat),
      let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(audio.frameCount))
    else { throw ApolloMLXError.audio("Can't set up resampler") }
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    input.frameLength = AVAudioFrameCount(audio.frameCount)
    for c in 0..<Int(ch) {
      audio.channels[c].withUnsafeBufferPointer { src in
        input.floatChannelData![c].update(from: src.baseAddress!, count: audio.frameCount)
      }
    }
    let expected = Int((Double(audio.frameCount) * Double(rate) / Double(audio.sampleRate)).rounded())
    var out = [[Float]](repeating: [], count: Int(ch))
    for c in out.indices { out[c].reserveCapacity(expected + 8192) }
    let fed = UncheckedBox(false)
    let inputBox = UncheckedBox(input)
    // One output buffer big enough for everything: the converter gets the whole input at once.
    let chunk = AVAudioFrameCount(expected + 8192)
    while true {
      guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
        throw ApolloMLXError.audio("Can't allocate audio buffer")
      }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, outStatus in
        if fed.value {
          outStatus.pointee = .endOfStream
          return nil
        }
        fed.value = true
        outStatus.pointee = .haveData
        return inputBox.value
      }
      if let error { throw ApolloMLXError.audio("Resample failed: \(error.localizedDescription)") }
      let n = Int(output.frameLength)
      for c in out.indices {
        out[c].append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![c], count: n))
      }
      if status == .endOfStream || status == .error || (n == 0 && fed.value) { break }
    }
    // Trim/pad to the exact expected length.
    for c in out.indices {
      if out[c].count > expected { out[c].removeLast(out[c].count - expected) }
      if out[c].count < expected { out[c].append(contentsOf: [Float](repeating: 0, count: expected - out[c].count)) }
    }
    return PCMAudio(channels: out, sampleRate: rate)
  }

  public enum WAVFormat: String, Sendable { case pcm24, float32 }

  /// Write interleaved WAV atomically. Returns the number of samples clipped (pcm24 only).
  @discardableResult
  public static func writeWAV(_ audio: PCMAudio, to url: URL, format: WAVFormat = .pcm24) throws -> Int {
    let channels = audio.channels.count, frames = audio.frameCount
    let bytesPerSample = format == .pcm24 ? 3 : 4
    let dataSize = frames * channels * bytesPerSample
    var d = Data()
    d.reserveCapacity(dataSize + 64)
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16)
    u16(format == .pcm24 ? 1 : 3); u16(channels); u32(audio.sampleRate)
    u32(audio.sampleRate * channels * bytesPerSample); u16(channels * bytesPerSample); u16(bytesPerSample * 8)
    d.append(contentsOf: Array("data".utf8)); u32(dataSize)
    var clipped = 0
    var body = [UInt8](repeating: 0, count: dataSize)
    var o = 0
    for i in 0..<frames {
      for c in 0..<channels {
        let s = audio.channels[c][i]
        if format == .float32 {
          let bits = s.bitPattern
          body[o] = UInt8(bits & 0xFF); body[o + 1] = UInt8(bits >> 8 & 0xFF)
          body[o + 2] = UInt8(bits >> 16 & 0xFF); body[o + 3] = UInt8(bits >> 24)
          o += 4
        } else {
          if abs(s) > 1 { clipped += 1 }
          let v = Int32((max(-1, min(1, s)) * 8_388_607).rounded())
          let u = UInt32(bitPattern: v)
          body[o] = UInt8(u & 0xFF); body[o + 1] = UInt8(u >> 8 & 0xFF); body[o + 2] = UInt8(u >> 16 & 0xFF)
          o += 3
        }
      }
    }
    d.append(contentsOf: body)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial-\(getpid())")
    try d.write(to: tmp)
    _ = try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
    return clipped
  }
}

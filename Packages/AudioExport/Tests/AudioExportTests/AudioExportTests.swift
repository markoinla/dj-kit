import AVFoundation
import Accelerate
import Foundation
import Testing
@testable import AudioExport

/// A synthesized stereo 24-bit WAV (like StemsKit's and Apollo's output),
/// converted to each format and decoded back with AVAudioFile.
@Suite("AudioExport")
struct AudioExportTests {
  static let seconds = 6.0

  let dir: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioExportTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  /// A tiny valid PNG, as stand-in cover art.
  static let png = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

  static let tags = AudioTags(title: "39 Hour Man (Vocals)", artist: "Acid Burp", album: "Exp036 — Ünïcode", artwork: png)

  // MARK: Lossless

  @Test(arguments: [AudioFileFormat.aiff, .wav, .flac])
  func losslessIsBitExact(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: Self.seconds)
    let out = dir.appendingPathComponent("out.\(format.fileExtension)")
    let written = try await AudioExporter.export(source, to: out, format: format, tags: Self.tags)
    #expect(written == out)

    let a = try Decoded(source), b = try Decoded(out)
    #expect(b.sampleRate == 44_100)
    #expect(b.channels == 2)
    #expect(b.frames == a.frames)
    #expect(b.bits == 24, "bits \(b.bits)")
    #expect(a.samples == b.samples, "max diff \(a.maxDiff(b))")
    if format == .flac {
      #expect(b.formatID == kAudioFormatFLAC)
    }
    // No partial files left behind.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") }
    #expect(leftovers.isEmpty)
  }

  @Test func sixteenBitSourceStaysSixteenBit() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1, bits: 16)
    for format in [AudioFileFormat.aiff, .flac] {
      let out = dir.appendingPathComponent("out16.\(format.fileExtension)")
      _ = try await AudioExporter.export(source, to: out, format: format)
      let a = try Decoded(source), b = try Decoded(out)
      #expect(b.bits == 16)
      #expect(a.samples == b.samples)
    }
  }

  /// Loudness normalization: every sample scaled, 24-bit out even from a 16-bit source.
  @Test(arguments: [AudioFileFormat.aiff, .flac])
  func gainScalesEverySample(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: 1, bits: 16)
    let out = dir.appendingPathComponent("gain.\(format.fileExtension)")
    _ = try await AudioExporter.export(source, to: out, format: format, gainDB: -6)
    let a = try Decoded(source), b = try Decoded(out)
    #expect(b.bits == 24)
    #expect(b.frames == a.frames)
    let g = Float(pow(10, -6.0 / 20))
    var worst: Float = 0
    for (x, y) in zip(a.samples, b.samples) {
      for (u, v) in zip(x, y) { worst = max(worst, abs(u * g - v)) }
    }
    #expect(worst <= 1.0 / Float(1 << 23), "max error \(worst)")
  }

  @Test func gainAppliesToMP3() async throws {
    let source = try Synth.wav24(in: dir, seconds: 2)
    let loud = dir.appendingPathComponent("loud.mp3"), quiet = dir.appendingPathComponent("quiet.mp3")
    _ = try await AudioExporter.export(source, to: loud, format: .mp3_320)
    _ = try await AudioExporter.export(source, to: quiet, format: .mp3_320, gainDB: -10)
    func rms(_ d: Decoded) -> Double {
      let x = d.samples[0]
      return (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot()
    }
    let difference = 20 * log10(rms(try Decoded(quiet)) / rms(try Decoded(loud)))
    #expect(abs(difference - -10) < 0.1, "\(difference) dB")
  }

  @Test func aiffCarriesAnID3Chunk() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("tagged.aiff")
    _ = try await AudioExporter.export(source, to: out, format: .aiff, tags: Self.tags)
    let data = try Data(contentsOf: out)
    // FORM size covers the whole file.
    let formSize = data[4..<8].reduce(0) { $0 << 8 | Int($1) }
    #expect(formSize == data.count - 8)
    #expect(data.range(of: Data("ID3 ".utf8)) != nil)
    let read = await AudioTags.read(from: out)
    #expect(read == Self.tags, "read back \(read)")
  }

  @Test func flacCarriesVorbisCommentsAndPicture() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("tagged.flac")
    _ = try await AudioExporter.export(source, to: out, format: .flac, tags: Self.tags)
    let data = try Data(contentsOf: out)
    #expect(data.range(of: Data("TITLE=39 Hour Man (Vocals)".utf8)) != nil)
    #expect(data.range(of: Data("ALBUM=Exp036 — Ünïcode".utf8)) != nil)
    #expect(data.range(of: Self.png) != nil)
    // Still decodes, same length.
    #expect(try Decoded(out).frames == 44_100)
    let read = await AudioTags.read(from: out)
    print("FLAC tags as AVFoundation reads them: \(read.title ?? "nil") / \(read.artist ?? "nil") / art \(read.artwork?.count ?? 0) B")
  }

  @Test func removingSourceDeletesTheWAV() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("moved.aiff")
    _ = try await AudioExporter.export(source, to: out, format: .aiff, removingSource: true)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: out.path))
  }

  @Test func replacesAnExistingFile() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("exists.wav")
    try Data("junk".utf8).write(to: out)
    _ = try await AudioExporter.export(source, to: out, format: .wav)
    #expect(try Decoded(out).frames == 44_100)
  }

  @Test func unreadableSourceThrows() async throws {
    let bogus = dir.appendingPathComponent("bogus.wav")
    try Data("not audio".utf8).write(to: bogus)
    await #expect(throws: AudioExportError.self) {
      try await AudioExporter.export(bogus, to: dir.appendingPathComponent("x.aiff"), format: .aiff)
    }
  }

  // MARK: MP3

  @Test(arguments: [AudioFileFormat.mp3_320, .mp3_256, .mp3_192])
  func mp3DecodesWithTheRightLength(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: Self.seconds)
    let out = dir.appendingPathComponent("out-\(format.rawValue).mp3")
    let start = Date()
    _ = try await AudioExporter.export(source, to: out, format: format, tags: Self.tags)
    let elapsed = Date().timeIntervalSince(start)
    let b = try Decoded(out)
    #expect(b.sampleRate == 44_100)
    #expect(b.channels == 2)
    let expected = Int64(Self.seconds * 44_100)
    #expect(abs(b.frames - expected) <= 1_152, "decoded \(b.frames) frames, wrote \(expected)")
    // CBR: the file size matches the bitrate (± the tag and one frame).
    let bytes = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
    let audioBytes = Double(bytes - ID3v2.tag(Self.tags).count)
    let kbps = audioBytes * 8 / Self.seconds / 1000
    #expect(abs(kbps - Double(format.mp3BitrateKbps!)) < Double(format.mp3BitrateKbps!) * 0.04, "\(kbps) kbps")
    let cutoff = b.cutoffHz()
    print("\(format.rawValue): \(b.frames) frames (wrote \(expected)), \(Int(kbps)) kbps, cutoff \(Int(cutoff)) Hz, encoded in \(String(format: "%.2f", elapsed)) s")
    #expect(cutoff > 18_000 && cutoff < 21_000, "cutoff \(cutoff)")
    if format == .mp3_320 { #expect(cutoff > 19_500, "cutoff \(cutoff)") }

    let read = await AudioTags.read(from: out)
    #expect(read == Self.tags, "read back \(read)")
  }

  /// 48 kHz down, and 24 kHz up (a 64 kbps MP3's stems): both come out 44.1 kHz.
  @Test(arguments: [48_000.0, 24_000.0, 22_050.0])
  func mp3IsResampledTo44k(rate: Double) async throws {
    let source = try Synth.wav24(in: dir, seconds: 2, sampleRate: rate)
    let out = dir.appendingPathComponent("\(Int(rate)).mp3")
    _ = try await AudioExporter.export(source, to: out, format: .mp3_320)
    let b = try Decoded(out)
    #expect(b.sampleRate == 44_100)
    #expect(abs(b.frames - 88_200) <= 1_152, "\(b.frames)")
  }

  @Test func mp3WithoutTagsStartsWithAFrame() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("bare.mp3")
    _ = try await AudioExporter.export(source, to: out, format: .mp3_192)
    let data = try Data(contentsOf: out)
    #expect(data[0] == 0xFF && data[1] & 0xE0 == 0xE0)
    // The first frame is the LAME/Info tag, filled in after encoding.
    #expect(data.prefix(400).range(of: Data("Info".utf8)) != nil)
  }

  @Test func titleSuffix() {
    #expect(AudioTags(title: "Song").suffixingTitle(" (Drums)", fallbackTitle: "file").title == "Song (Drums)")
    #expect(AudioTags().suffixingTitle(" (Repaired)", fallbackTitle: "file").title == "file (Repaired)")
    #expect(AudioTags(title: "  ").suffixingTitle(" (Bass)", fallbackTitle: "file").title == "file (Bass)")
  }

  @Test func formatNames() {
    #expect(AudioFileFormat(rawValue: "mp3-320") == .mp3_320)
    #expect(AudioFileFormat.mp3_256.fileExtension == "mp3")
    #expect(AudioFileFormat.aiff.title == "AIFF")
    #expect(AudioFileFormat.mp3_192.title == "MP3 192 kbps")
    #expect(!AudioFileFormat.mp3_320.isLossless && AudioFileFormat.flac.isLossless)
  }
}

// MARK: - Helpers

enum Synth {
  /// Full-band white noise plus a sine sweep, quantized to the bit depth, written
  /// as a stereo PCM WAV.
  static func wav24(in dir: URL, seconds: Double, sampleRate: Double = 44_100, bits: Int = 24) throws -> URL {
    let url = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let frames = Int(seconds * sampleRate)
    do {
      let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      var state: UInt64 = 0x1234_5678
      let scale = Float(1 << (bits - 1))
      for c in 0..<2 {
        let ch = buffer.floatChannelData![c]
        for i in 0..<frames {
          state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          let noise = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)  // -1…1
          let t = Double(i) / sampleRate
          let sweep = Float(sin(2 * .pi * (100 * t + 1_500 * t * t))) * (c == 0 ? 1 : 0.7)
          let x = 0.25 * noise + 0.3 * sweep
          ch[i] = (x * scale).rounded() / scale
        }
      }
      try file.write(from: buffer)
    }
    return url
  }
}

struct Decoded {
  let sampleRate: Double
  let channels: Int
  let frames: Int64
  let bits: Int
  let formatID: AudioFormatID
  let samples: [[Float]]

  init(_ url: URL) throws {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    sampleRate = file.processingFormat.sampleRate
    channels = Int(file.processingFormat.channelCount)
    frames = file.length
    let asbd = file.fileFormat.streamDescription.pointee
    formatID = asbd.mFormatID
    if asbd.mFormatID == kAudioFormatFLAC {
      bits = asbd.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData ? 24
        : asbd.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData ? 16 : Int(asbd.mFormatFlags)
    } else {
      bits = Int(asbd.mBitsPerChannel)
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    samples = (0..<channels).map { c in Array(UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
  }

  func maxDiff(_ other: Decoded) -> Float {
    var worst: Float = 0
    for (a, b) in zip(samples, other.samples) {
      for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
    }
    return worst
  }

  /// The highest frequency whose average level is within 50 dB of the
  /// 2–10 kHz average (channel 0, Hann-windowed 4096-point FFTs).
  func cutoffHz() -> Double {
    let log2n = 12, n = 1 << log2n, half = n / 2
    let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var power = [Float](repeating: 0, count: half)
    let x = samples[0]
    var count = 0
    var start = 0
    while start + n <= x.count {
      var frame = [Float](repeating: 0, count: n)
      vDSP_vmul(Array(x[start..<start + n]), 1, window, 1, &frame, 1, vDSP_Length(n))
      var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
      real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
          var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
          frame.withUnsafeBytes { raw in
            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
          }
          vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
          var mags = [Float](repeating: 0, count: half)
          vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
          vDSP_vadd(power, 1, mags, 1, &power, 1, vDSP_Length(half))
        }
      }
      count += 1
      start += n
    }
    let binHz = sampleRate / Double(n)
    let ref = (Int(2_000 / binHz)..<Int(10_000 / binHz)).map { Double(power[$0]) }.reduce(0, +)
      / Double(Int(10_000 / binHz) - Int(2_000 / binHz))
    let threshold = ref * pow(10, -50 / 10)
    var cutoff = 0
    for k in 1..<half where Double(power[k]) > threshold { cutoff = k }
    return Double(cutoff) * binHz
  }
}

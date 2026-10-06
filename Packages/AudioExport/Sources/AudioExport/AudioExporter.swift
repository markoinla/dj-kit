import AVFoundation
import AudioToolbox
import CLAME
import Foundation

public enum AudioExportError: LocalizedError, Equatable {
  case unreadable(String)
  case coreAudio(OSStatus, String)
  case encoder(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let why): "Couldn't read the audio to save it: \(why)"
    case .coreAudio(let status, let step): "Couldn't save the audio (\(step), error \(status))."
    case .encoder(let why): "Couldn't save the audio: \(why)"
    }
  }
}

/// Converts a finished PCM file (the engines' WAVs) to the chosen format.
public enum AudioExporter {
  /// Writes `source` (any PCM file AVAudioFile reads, normally a 24-bit WAV) to
  /// `destination` as `format`, replacing whatever is there, and returns it.
  ///
  /// - Lossless formats keep the source's sample rate and bit depth (24-bit,
  ///   or 16-bit for a 16-bit source; float sources become 24-bit) and are
  ///   bit-exact.
  /// - MP3 is LAME CBR at the format's bitrate, joint stereo, `-q 0`,
  ///   resampled to 44.1 kHz if needed, with a LAME/Info tag (gapless).
  /// - `tags` go into AIFF (ID3 chunk), FLAC (Vorbis comments + picture) and
  ///   MP3 (ID3v2.3); WAV gets none.
  ///
  /// The file appears atomically (written beside it, then moved into place).
  /// `removingSource` deletes `source` once the destination exists. Runs off
  /// the caller's executor; cancelling the calling task stops it and leaves
  /// nothing behind. `progress` (0…1) is called from a background thread.
  public static func export(
    _ source: URL, to destination: URL, format: AudioFileFormat,
    tags: AudioTags? = nil, removingSource: Bool = false,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> URL {
    let work = Task.detached(priority: .userInitiated) {
      try convert(source, to: destination, format: format, tags: tags, progress: progress)
    }
    let written = try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
    if removingSource, source.standardizedFileURL != written.standardizedFileURL {
      try? FileManager.default.removeItem(at: source)
    }
    return written
  }

  static let chunkFrames: AVAudioFrameCount = 1 << 15

  static func convert(
    _ source: URL, to destination: URL, format: AudioFileFormat,
    tags: AudioTags?, progress: (@Sendable (Double) -> Void)?
  ) throws -> URL {
    let input: AVAudioFile
    do {
      input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
      throw AudioExportError.unreadable(error.localizedDescription)
    }
    let fm = FileManager.default
    let folder = destination.deletingLastPathComponent()
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = folder.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
    defer { try? fm.removeItem(at: partial) }

    progress?(0)
    switch format {
    case .aiff, .wav, .flac:
      try writeLossless(input, to: partial, format: format, progress: progress)
      if let tags, !tags.isEmpty {
        if format == .aiff { try appendAIFFID3Chunk(ID3v2.tag(tags), to: partial) }
        if format == .flac {
          let retagged = try FLACTags.retag(Data(contentsOf: partial, options: .alwaysMapped), with: tags)
          try retagged.write(to: partial)
        }
      }
    case .mp3_320, .mp3_256, .mp3_192:
      try writeMP3(input, to: partial, kbps: format.mp3BitrateKbps!, tags: tags, progress: progress)
    }
    try Task.checkCancellation()
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.moveItem(at: partial, to: destination)
    progress?(1)
    return destination
  }

  /// Integer bit depth for lossless output: the source's 16 or 24, else 24.
  static func bitDepth(of file: AVAudioFile) -> UInt32 {
    let settings = file.fileFormat.settings
    let isFloat = (settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
    let bits = (settings[AVLinearPCMBitDepthKey] as? Int) ?? 24
    return !isFloat && bits <= 16 ? 16 : 24
  }

  // MARK: - AIFF / WAV / FLAC (Core Audio)

  private static func writeLossless(
    _ input: AVAudioFile, to url: URL, format: AudioFileFormat,
    progress: (@Sendable (Double) -> Void)?
  ) throws {
    let bits = bitDepth(of: input)
    let channels = input.processingFormat.channelCount
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = input.processingFormat.sampleRate
    asbd.mChannelsPerFrame = channels
    let fileType: AudioFileTypeID
    switch format {
    case .flac:
      fileType = kAudioFileFLACType
      asbd.mFormatID = kAudioFormatFLAC
      asbd.mFormatFlags = bits == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &asbd)
      guard status == noErr else { throw AudioExportError.coreAudio(status, "FLAC format") }
    default:
      fileType = format == .aiff ? kAudioFileAIFFType : kAudioFileWAVEType
      asbd.mFormatID = kAudioFormatLinearPCM
      asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        | (format == .aiff ? kLinearPCMFormatFlagIsBigEndian : 0)
      asbd.mBitsPerChannel = bits
      asbd.mBytesPerFrame = bits / 8 * channels
      asbd.mFramesPerPacket = 1
      asbd.mBytesPerPacket = asbd.mBytesPerFrame
    }

    var fileRef: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
      url as CFURL, fileType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &fileRef)
    guard status == noErr, let file = fileRef else { throw AudioExportError.coreAudio(status, "create file") }
    var disposed = false
    defer { if !disposed { ExtAudioFileDispose(file) } }

    var client = input.processingFormat.streamDescription.pointee
    status = ExtAudioFileSetProperty(
      file, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
    guard status == noErr else { throw AudioExportError.coreAudio(status, "client format") }

    try forEachChunk(of: input, progress: progress) { buffer in
      let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
      guard status == noErr else { throw AudioExportError.coreAudio(status, "write") }
    }
    disposed = true
    status = ExtAudioFileDispose(file)
    guard status == noErr else { throw AudioExportError.coreAudio(status, "finish file") }
  }

  /// Reads `input` from the start in chunks, checking for cancellation.
  private static func forEachChunk(
    of input: AVAudioFile, progress: (@Sendable (Double) -> Void)?,
    _ body: (AVAudioPCMBuffer) throws -> Void
  ) throws {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else {
      throw AudioExportError.unreadable("no buffer")
    }
    input.framePosition = 0
    let total = max(input.length, 1)
    while input.framePosition < input.length {
      try Task.checkCancellation()
      do {
        try input.read(into: buffer, frameCount: chunkFrames)
      } catch {
        throw AudioExportError.unreadable(error.localizedDescription)
      }
      if buffer.frameLength == 0 { break }
      try body(buffer)
      // The last 2% is the tags and the move.
      progress?(0.98 * Double(input.framePosition) / Double(total))
    }
  }

  /// Appends an "ID3 " chunk to an AIFF file and fixes the FORM size.
  static func appendAIFFID3Chunk(_ tag: Data, to url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    var chunk = Data("ID3 ".utf8)
    chunk.append(bigEndian32(UInt32(tag.count)))
    chunk.append(tag)
    if tag.count % 2 == 1 { chunk.append(0) }
    let end = try handle.seekToEnd()
    try handle.write(contentsOf: chunk)
    try handle.seek(toOffset: 4)
    try handle.write(contentsOf: bigEndian32(UInt32(end + UInt64(chunk.count) - 8)))
  }

  // MARK: - MP3 (LAME)

  private static func writeMP3(
    _ input: AVAudioFile, to url: URL, kbps: Int, tags: AudioTags?,
    progress: (@Sendable (Double) -> Void)?
  ) throws {
    let channels = Int(input.processingFormat.channelCount)
    guard channels >= 1 else { throw AudioExportError.unreadable("no channels") }
    guard let lame = lame_init() else { throw AudioExportError.encoder("LAME didn't start.") }
    defer { lame_close(lame) }
    lame_set_in_samplerate(lame, Int32(input.processingFormat.sampleRate.rounded()))
    lame_set_num_channels(lame, channels == 1 ? 1 : 2)
    lame_set_out_samplerate(lame, 44_100)
    lame_set_VBR(lame, vbr_off)
    lame_set_brate(lame, Int32(kbps))
    lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
    lame_set_quality(lame, 0)
    lame_set_write_id3tag_automatic(lame, 0)
    lame_set_bWriteVbrTag(lame, 1)  // the LAME/Info frame: length, encoder delay, padding
    guard lame_init_params(lame) >= 0 else { throw AudioExportError.encoder("LAME rejected the settings.") }

    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw AudioExportError.encoder("can't create \(url.lastPathComponent)")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var tagBytes = 0
    if let tags, !tags.isEmpty {
      let tag = ID3v2.tag(tags)
      try handle.write(contentsOf: tag)
      tagBytes = tag.count
    }

    // LAME's worst case is 1.25 × output samples + 7200; resampling up (a 24 kHz
    // source) makes more output samples than input frames.
    let ratio = max(1, 44_100 / input.processingFormat.sampleRate)
    let capacity = Int((Double(chunkFrames) * ratio).rounded(.up)) * 5 / 4 + 7_200
    var mp3 = [UInt8](repeating: 0, count: capacity)
    func emit(_ count: Int32) throws {
      guard count >= 0 else { throw AudioExportError.encoder("LAME error \(count).") }
      if count > 0 { try handle.write(contentsOf: mp3[0..<Int(count)]) }
    }

    try forEachChunk(of: input, progress: progress) { buffer in
      guard let data = buffer.floatChannelData else { throw AudioExportError.unreadable("not float") }
      let left = data[0], right = channels > 1 ? data[1] : data[0]
      let count = mp3.withUnsafeMutableBufferPointer { out in
        lame_encode_buffer_ieee_float(lame, left, right, Int32(buffer.frameLength), out.baseAddress, Int32(capacity))
      }
      try emit(count)
    }
    let flushed = mp3.withUnsafeMutableBufferPointer { out in
      lame_encode_flush(lame, out.baseAddress, Int32(capacity))
    }
    try emit(flushed)

    // The first audio frame was a placeholder for the LAME tag; fill it in.
    let tagSize = lame_get_lametag_frame(lame, nil, 0)
    if tagSize > 0 {
      var frame = [UInt8](repeating: 0, count: tagSize)
      let written = frame.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, tagSize) }
      if written == tagSize {
        try handle.seek(toOffset: UInt64(tagBytes))
        try handle.write(contentsOf: frame)
      }
    }
  }
}

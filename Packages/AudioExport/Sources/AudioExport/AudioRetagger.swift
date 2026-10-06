import AVFoundation
import Foundation

public enum AudioRetagError: LocalizedError, Equatable {
  /// A file type tags can't be written into (raw AAC, Ogg, …); the message says which.
  case unsupported(String)
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .unsupported(let why): why
    case .failed(let why): "Couldn't write the tags: \(why)"
    }
  }
}

/// Rewrites the tags of an existing file without touching its audio.
public enum AudioRetagger {
  /// Merges `tags` into `url`'s tags and returns where the file ended up.
  ///
  /// Every non-nil field replaces the matching tag (empty BPM / key count as nil);
  /// everything else in the file (other comments, Rekordbox and Serato frames, …)
  /// stays as it was.
  /// Non-nil artwork replaces the front-cover picture(s). The audio is never
  /// re-encoded: MP3, AIFF, WAV and FLAC audio bytes come out identical; M4A goes
  /// through an AVFoundation passthrough export (same samples, new container).
  ///
  /// - MP3: the leading ID3v2 tag, kept as v2.3 or v2.4 (v2.2 becomes v2.3); a
  ///   trailing ID3v1 tag is left alone.
  /// - AIFF / WAV: the "ID3 " chunk, added when missing.
  /// - FLAC: Vorbis comments and PICTURE blocks.
  /// - M4A: iTunes atoms (label, ISRC and key as "----:com.apple.iTunes:" atoms;
  ///   BPM rounded into "tmpo", left alone when it isn't a number).
  ///
  /// The new file is written beside the target and then swapped in, so the
  /// original stays intact if anything fails or the task is cancelled. With
  /// `destination` (which must be free), the result is moved there and `url`
  /// no longer exists.
  public static func retag(_ url: URL, with tags: AudioTags, moveTo destination: URL? = nil) async throws -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { throw AudioRetagError.failed("the file isn't there any more.") }
    let kind = TagFile.kind(url)
    switch kind {
    case .aac: throw AudioRetagError.unsupported("Can't write tags into a raw AAC file.")
    case .rf64: throw AudioRetagError.unsupported("Can't write tags into an RF64 WAV file.")
    case .unknown: throw AudioRetagError.unsupported("Can't write tags into this kind of file.")
    case .mp3, .aiff, .wav, .flac, .m4a: break
    }

    let target = destination ?? url
    let folder = target.deletingLastPathComponent()
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let partial = folder.appendingPathComponent(
      ".\(target.lastPathComponent).\(UUID().uuidString).partial" + (kind == .m4a ? ".m4a" : ""))
    defer { try? fm.removeItem(at: partial) }

    if kind == .m4a {
      try await M4ARetagger.write(url, to: partial, tags: tags)
    } else {
      let work = Task.detached(priority: .userInitiated) {
        try write(kind, from: url, to: partial, tags: tags)
      }
      try await withTaskCancellationHandler {
        try await work.value
      } onCancel: {
        work.cancel()
      }
    }
    try Task.checkCancellation()

    let attributes = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
    let keep = attributes.filter { $0.key == .posixPermissions || $0.key == .creationDate }
    if !keep.isEmpty { try? fm.setAttributes(keep, ofItemAtPath: partial.path) }

    guard let destination, destination.standardizedFileURL.path != url.standardizedFileURL.path else {
      _ = try fm.replaceItemAt(url, withItemAt: partial)
      return url
    }
    if destination.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() {
      // Only the case changes: same file on a case-insensitive volume.
      _ = try fm.replaceItemAt(url, withItemAt: partial)
      guard rename(url.path, destination.path) == 0 else {
        throw AudioRetagError.failed("couldn't rename the file (\(String(cString: strerror(errno)))).")
      }
      return destination
    }
    try fm.moveItem(at: partial, to: destination)
    do {
      try fm.removeItem(at: url)
    } catch {
      try? fm.removeItem(at: destination)
      throw error
    }
    return destination
  }

  private static func write(_ kind: TagFile.Kind, from url: URL, to partial: URL, tags: AudioTags) throws {
    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
      throw AudioRetagError.failed("can't write next to \(partial.deletingLastPathComponent().lastPathComponent).")
    }
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: partial)
    defer { try? output.close() }
    switch kind {
    case .mp3: try writeMP3(input, to: output, tags: tags)
    case .aiff: try writeChunks(input, to: output, tags: tags, bigEndian: true)
    case .wav: try writeChunks(input, to: output, tags: tags, bigEndian: false)
    case .flac: try writeFLAC(url, to: output, tags: tags)
    case .m4a, .aac, .rf64, .unknown: break
    }
    try output.synchronize()
  }

  // MARK: MP3

  /// New ID3v2 tag, then everything after the old one (audio, APE, ID3v1) byte for byte.
  private static func writeMP3(_ input: FileHandle, to output: FileHandle, tags: AudioTags) throws {
    let size = try input.seekToEnd()
    try input.seek(toOffset: 0)
    let header = try input.read(upToCount: 10) ?? Data()
    var tag = ID3Tag()
    var audioStart: UInt64 = 0
    if let total = ID3Tag.totalSize(header: header) {
      guard UInt64(total) <= size else { throw AudioRetagError.failed("the MP3's tag runs past the end of the file.") }
      try input.seek(toOffset: 0)
      tag = ID3Tag.parse(try input.read(upToCount: total) ?? Data()) ?? ID3Tag()
      audioStart = UInt64(total)
    }
    tag.merge(tags)
    try output.write(contentsOf: tag.serialized())
    try copy(input, from: audioStart, to: size, into: output)
  }

  // MARK: AIFF / WAV

  /// Same chunks in the same order with the ID3 chunk merged (or added at the
  /// end), FORM / RIFF size fixed. Extra ID3 chunks are dropped.
  private static func writeChunks(_ input: FileHandle, to output: FileHandle, tags: AudioTags, bigEndian: Bool) throws {
    let layout = try TagFile.chunks(input, bigEndian: bigEndian)
    let audioID = bigEndian ? "SSND" : "data"
    guard layout.chunks.contains(where: { $0.name == audioID }) else {
      throw AudioRetagError.failed("the file has no audio chunk.")
    }
    let id3 = layout.chunks.filter(\.isID3)
    var tag = ID3Tag()
    if let first = id3.first {
      try input.seek(toOffset: first.dataOffset)
      tag = ID3Tag.parse(try input.read(upToCount: Int(first.size)) ?? Data()) ?? ID3Tag()
    }
    tag.merge(tags)
    let tagData = tag.serialized()

    func u32(_ v: UInt64) -> Data { bigEndian ? bigEndian32(UInt32(v)) : littleEndian32(UInt32(v)) }
    try output.write(contentsOf: layout.header)
    var formSize: UInt64 = 4  // the form type
    func writeTag(id: Data) throws {
      var chunk = id
      chunk.append(u32(UInt64(tagData.count)))
      chunk.append(tagData)
      if tagData.count % 2 == 1 { chunk.append(0) }
      try output.write(contentsOf: chunk)
      formSize += UInt64(chunk.count)
    }
    for chunk in layout.chunks {
      if chunk.isID3 {
        if chunk.offset == id3.first?.offset { try writeTag(id: chunk.id) }
        continue
      }
      var header = chunk.id
      header.append(u32(chunk.size))
      try output.write(contentsOf: header)
      try copy(input, from: chunk.dataOffset, to: chunk.dataOffset + chunk.size, into: output)
      if chunk.size % 2 == 1 { try output.write(contentsOf: Data([0])) }
      formSize += 8 + chunk.size + chunk.size % 2
    }
    if id3.isEmpty { try writeTag(id: Data((bigEndian ? "ID3 " : "id3 ").utf8)) }
    guard formSize <= UInt64(UInt32.max) else { throw AudioRetagError.failed("the file would be over 4 GB.") }
    // Anything after the FORM / RIFF stays where it was.
    try copy(input, from: layout.end, to: layout.fileSize, into: output)
    try output.seek(toOffset: 4)
    try output.write(contentsOf: u32(formSize))
  }

  // MARK: FLAC

  /// Merged metadata blocks, then the audio frames byte for byte. A leading
  /// ID3 tag (non-standard, but it happens) is kept as it is.
  private static func writeFLAC(_ url: URL, to output: FileHandle, tags: AudioTags) throws {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    var start = 0
    if let total = ID3Tag.totalSize(header: data.prefix(10)) { start = total }
    guard let (blocks, audioStart) = FLACTags.blocks(in: data, at: start) else {
      throw AudioRetagError.failed("the FLAC file's metadata is damaged.")
    }
    try output.write(contentsOf: data.prefix(start))
    try output.write(contentsOf: FLACTags.metadata(FLACTags.merged(blocks, with: tags)))
    var offset = audioStart
    while offset < data.count {
      try Task.checkCancellation()
      let end = min(offset + (4 << 20), data.count)
      try autoreleasepool { try output.write(contentsOf: data[(data.startIndex + offset)..<(data.startIndex + end)]) }
      offset = end
    }
  }

  // MARK: Copying

  /// Streams `start..<end` of `input` to `output`, 1 MB at a time.
  static func copy(_ input: FileHandle, from start: UInt64, to end: UInt64, into output: FileHandle) throws {
    guard end > start else { return }
    try input.seek(toOffset: start)
    var left = end - start
    while left > 0 {
      try Task.checkCancellation()
      let chunk = try autoreleasepool { try input.read(upToCount: Int(min(left, 1 << 20))) } ?? Data()
      guard !chunk.isEmpty else { throw AudioRetagError.failed("the file is shorter than it says.") }
      try output.write(contentsOf: chunk)
      left -= UInt64(chunk.count)
    }
  }
}

// MARK: - M4A

/// Passthrough export with the merged iTunes metadata. The samples are copied, not re-encoded.
private enum M4ARetagger {
  /// AVExportSession isn't Sendable; this only crosses into the cancel handler.
  private final class Session: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
  }

  static func write(_ url: URL, to partial: URL, tags: AudioTags) async throws {
    let asset = AVURLAsset(url: url)
    let existing: [AVMetadataItem]
    do {
      existing = try await asset.load(.metadata)
    } catch {
      throw AudioRetagError.failed("couldn't read the file (\(error.localizedDescription)).")
    }

    var replacedIDs: Set<AVMetadataIdentifier> = []
    var replacedKeys: Set<AVMetadataKey> = []
    var added: [AVMetadataItem] = []
    func put(_ value: String?, _ id: AVMetadataIdentifier, replacing ids: [AVMetadataIdentifier], common: AVMetadataKey? = nil) {
      guard let value else { return }
      replacedIDs.formUnion(ids + [id])
      if let common { replacedKeys.insert(common) }
      let item = AVMutableMetadataItem()
      item.identifier = id
      item.value = value as NSString
      item.dataType = kCMMetadataBaseDataType_UTF8 as String
      added.append(item)
    }
    put(tags.title, .iTunesMetadataSongName, replacing: [.quickTimeMetadataTitle], common: .commonKeyTitle)
    put(tags.artist, .iTunesMetadataArtist, replacing: [.quickTimeMetadataArtist], common: .commonKeyArtist)
    put(tags.album, .iTunesMetadataAlbum, replacing: [.quickTimeMetadataAlbum], common: .commonKeyAlbumName)
    put(tags.genre, .iTunesMetadataUserGenre, replacing: [.iTunesMetadataPredefinedGenre, .quickTimeMetadataGenre])
    put(tags.year, .iTunesMetadataReleaseDate, replacing: [.quickTimeMetadataYear])
    put(tags.label, M4AKeys.label, replacing: [])
    put(tags.isrc, M4AKeys.isrc, replacing: [])
    put(tags.comment, .iTunesMetadataUserComment, replacing: [.quickTimeMetadataComment])
    put(tags.keyText, M4AKeys.initialKey, replacing: [M4AKeys.initialKeyUpper])
    if let bpm = tags.bpmText.flatMap(Double.init), bpm.isFinite, bpm >= 1, bpm < 1000 {
      replacedIDs.insert(.iTunesMetadataBeatsPerMin)
      let item = AVMutableMetadataItem()
      item.identifier = .iTunesMetadataBeatsPerMin
      item.value = NSNumber(value: Int16(bpm.rounded()))
      item.dataType = kCMMetadataBaseDataType_SInt16 as String
      added.append(item)
    }
    if let artwork = tags.artwork {
      replacedIDs.formUnion([.iTunesMetadataCoverArt, .quickTimeMetadataArtwork])
      replacedKeys.insert(.commonKeyArtwork)
      let item = AVMutableMetadataItem()
      item.identifier = .iTunesMetadataCoverArt
      item.value = artwork as NSData
      item.dataType = (tags.artworkMIMEType == "image/png" ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
      added.append(item)
    }
    let kept = existing.filter { item in
      !(item.identifier.map(replacedIDs.contains) ?? false) && !(item.commonKey.map(replacedKeys.contains) ?? false)
    }

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw AudioRetagError.failed("AVFoundation can't copy this file.")
    }
    session.outputURL = partial
    session.outputFileType = .m4a
    session.metadata = kept + added
    let box = Session(session)
    await withTaskCancellationHandler {
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        box.session.exportAsynchronously { done.resume() }
      }
    } onCancel: {
      box.session.cancelExport()
    }
    try Task.checkCancellation()
    guard box.session.status == .completed else {
      throw AudioRetagError.failed(box.session.error?.localizedDescription ?? "AVFoundation couldn't copy the file.")
    }
  }
}

// MARK: - File layout

/// What kind of file this is (from its bytes) and where its tags live.
enum TagFile {
  enum Kind { case mp3, aiff, wav, flac, m4a, aac, rf64, unknown }

  static func kind(_ url: URL) -> Kind {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
    defer { try? handle.close() }
    guard var head = try? handle.read(upToCount: 12) else { return .unknown }
    var afterID3 = false
    if let total = ID3Tag.totalSize(header: head) {
      afterID3 = true
      guard (try? handle.seek(toOffset: UInt64(total))) != nil, let next = try? handle.read(upToCount: 12) else {
        return .mp3
      }
      head = next
    }
    let b = [UInt8](head)
    func ascii(_ range: Range<Int>) -> String {
      b.count >= range.upperBound ? String(decoding: b[range], as: UTF8.self) : ""
    }
    if ascii(0..<4) == "fLaC" { return .flac }
    if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return b[1] & 0x06 == 0 ? .aac : .mp3 }
    if afterID3 { return url.pathExtension.lowercased() == "aac" ? .aac : .mp3 }
    switch (ascii(0..<4), ascii(8..<12)) {
    case ("FORM", "AIFF"), ("FORM", "AIFC"): return .aiff
    case ("RIFF", "WAVE"): return .wav
    case ("RF64", _), ("BW64", _): return .rf64
    default: break
    }
    if ascii(4..<8) == "ftyp" { return .m4a }
    switch url.pathExtension.lowercased() {
    case "mp3": return .mp3
    case "aac": return .aac
    default: return .unknown
    }
  }

  /// Our own reading of the tags for MP3, AIFF, WAV and FLAC; nil for other files.
  static func read(_ url: URL) -> AudioTags? {
    let kind = kind(url)
    switch kind {
    case .mp3:
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      guard let header = try? handle.read(upToCount: 10), let total = ID3Tag.totalSize(header: header) else {
        return AudioTags()
      }
      try? handle.seek(toOffset: 0)
      guard let data = try? handle.read(upToCount: total), let tag = ID3Tag.parse(data) else { return AudioTags() }
      return tag.audioTags
    case .aiff, .wav:
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      guard let layout = try? chunks(handle, bigEndian: kind == .aiff) else { return nil }
      guard let chunk = layout.chunks.first(where: \.isID3) else { return AudioTags() }
      guard (try? handle.seek(toOffset: chunk.dataOffset)) != nil,
        let data = try? handle.read(upToCount: Int(chunk.size)), let tag = ID3Tag.parse(data)
      else { return AudioTags() }
      return tag.audioTags
    case .flac:
      guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
      let start = ID3Tag.totalSize(header: data.prefix(10)) ?? 0
      return FLACTags.blocks(in: data, at: start).map { FLACTags.audioTags($0.blocks) }
    case .m4a, .aac, .rf64, .unknown:
      return nil
    }
  }

  struct Chunk {
    /// The four ID bytes as stored.
    let id: Data
    /// Where the chunk header starts.
    let offset: UInt64
    /// Data size, without the pad byte.
    let size: UInt64

    var dataOffset: UInt64 { offset + 8 }
    var name: String { String(decoding: id, as: UTF8.self) }
    var isID3: Bool { name.lowercased() == "id3 " }
  }

  struct Layout {
    /// "FORM"/"RIFF", size, form type.
    let header: Data
    let chunks: [Chunk]
    /// Where the last chunk (and its pad byte) ends.
    let end: UInt64
    let fileSize: UInt64
  }

  /// The chunks of an AIFF (big-endian) or WAV (little-endian) file.
  static func chunks(_ handle: FileHandle, bigEndian: Bool) throws -> Layout {
    let fileSize = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    let header = try handle.read(upToCount: 12) ?? Data()
    guard header.count == 12 else { throw AudioRetagError.failed("the file is too short.") }
    func u32(_ d: Data) -> UInt64 {
      let b = [UInt8](d)
      return bigEndian
        ? UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
        : UInt64(b[3]) << 24 | UInt64(b[2]) << 16 | UInt64(b[1]) << 8 | UInt64(b[0])
    }
    let declared = u32(header[4..<8])
    // A streaming writer may leave the size 0 or too big; then the file's end is the form's end.
    let formEnd = declared == 0 || 8 + declared > fileSize ? fileSize : 8 + declared
    var chunks: [Chunk] = []
    var pos: UInt64 = 12
    while pos + 8 <= formEnd {
      try handle.seek(toOffset: pos)
      let head = try handle.read(upToCount: 8) ?? Data()
      guard head.count == 8 else { break }
      let size = u32(head[head.startIndex + 4..<head.startIndex + 8])
      guard pos + 8 + size <= fileSize else {
        throw AudioRetagError.failed("the file is cut short or damaged, so its tags weren't changed.")
      }
      chunks.append(Chunk(id: Data(head.prefix(4)), offset: pos, size: size))
      pos += 8 + size + size % 2
    }
    return Layout(header: header, chunks: chunks, end: min(pos, fileSize), fileSize: fileSize)
  }
}

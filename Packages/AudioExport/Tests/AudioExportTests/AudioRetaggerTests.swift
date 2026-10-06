import AVFoundation
import Foundation
import Testing
@testable import AudioExport

/// Files made by the exporter, given extra tags by hand (BPM, a Serato-style
/// GEOB, an iTunNORM comment, a back-cover picture), retagged, then checked:
/// new fields read back, the extras survive, the audio bytes are identical.
@Suite("AudioRetagger")
struct AudioRetaggerTests {
  let dir: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioRetaggerTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static let png = AudioExportTests.png
  /// A different "image": a JPEG header and some bytes.
  static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x42, count: 300) + [0xFF, 0xD9])

  static let old = AudioTags(title: "Unknown Track", artist: "Unknown", album: "Old Album", artwork: png)
  static let identified = AudioTags(
    title: "Windowlicker", artist: "Aphex Twin — Ünïcode", artwork: jpeg, genre: "Electronic",
    year: "1999-03-22", label: "Warp", isrc: "GBBPW9900001", comment: "Identified by Shazam")

  /// A Serato-style GEOB frame, over 127 bytes so v2.3 and v2.4 sizes differ.
  static let geob: ID3Tag.Frame = {
    var body = Data([0x00]) + Data("application/octet-stream".utf8) + Data([0]) + Data([0])
    body += Data("Serato Markers2".utf8) + Data([0]) + Data((0..<256).map { UInt8($0) })
    return ID3Tag.Frame(id: "GEOB", body: body)
  }()

  /// Extra frames a DJ library leaves in a file.
  static let extras: [ID3Tag.Frame] = {
    var itunnorm = Data([0x00]) + Data("eng".utf8) + Data("iTunNORM".utf8) + Data([0])
    itunnorm += Data(" 00000A 00000B".utf8)
    return [.text("TBPM", "128"), .text("TKEY", "8A"), geob, ID3Tag.Frame(id: "COMM", body: itunnorm)]
  }()

  /// Checks the merged result: new fields in, untouched fields kept.
  func expectMerged(_ read: AudioTags, year: String) {
    #expect(read.title == "Windowlicker")
    #expect(read.artist == "Aphex Twin — Ünïcode")
    #expect(read.album == "Old Album")
    #expect(read.genre == "Electronic")
    #expect(read.year == year)
    #expect(read.label == "Warp")
    #expect(read.isrc == "GBBPW9900001")
    #expect(read.comment == "Identified by Shazam")
    #expect(read.artwork == Self.jpeg)
  }

  func expectNoLeftovers() throws {
    let items = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
    #expect(!items.contains { $0.contains(".partial") }, "\(items)")
  }

  /// The tag with the extras added, as stored in a file.
  func tag(_ tags: AudioTags, major: UInt8 = 3) -> ID3Tag {
    var tag = ID3Tag(major: major)
    tag.merge(tags)
    tag.frames += Self.extras
    return tag
  }

  func expectExtras(_ tag: ID3Tag?) {
    guard let tag else { Issue.record("no tag"); return }
    for extra in Self.extras {
      #expect(tag.frames.contains { $0.id == extra.id && $0.body == extra.body }, "lost \(extra.id)")
    }
    #expect(tag.frames.filter { $0.id == "APIC" }.count == 1)
    #expect(tag.frames.filter { $0.id == "TIT2" }.count == 1)
  }

  // MARK: AIFF / WAV

  @Test func aiff() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("track.aiff")
    _ = try await AudioExporter.export(source, to: file, format: .aiff)
    try AudioExporter.appendAIFFID3Chunk(tag(Self.old).serialized(), to: file)
    let before = try chunk("SSND", of: file, bigEndian: true)

    let result = try await AudioRetagger.retag(file, with: Self.identified)
    #expect(result == file)
    expectMerged(await AudioTags.read(from: file), year: "1999")
    #expect(try chunk("SSND", of: file, bigEndian: true) == before)
    let data = try Data(contentsOf: file)
    #expect(data[4..<8].reduce(0) { $0 << 8 | Int($1) } == data.count - 8)
    expectExtras(ID3Tag.parse(try chunk("ID3 ", of: file, bigEndian: true)))
    #expect(try Decoded(file).samples == Decoded(source).samples)
    // AVFoundation still reads it.
    let common = try await AVURLAsset(url: file).load(.commonMetadata)
    let title = try await AVMetadataItem.metadataItems(from: common, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common)
      .first?.load(.stringValue)
    #expect(title == "Windowlicker")
    try expectNoLeftovers()
  }

  @Test func wav() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1, bits: 16)
    let file = dir.appendingPathComponent("track.wav")
    _ = try await AudioExporter.export(source, to: file, format: .wav)
    let before = try chunk("data", of: file, bigEndian: false)

    // No tag yet: one is added.
    _ = try await AudioRetagger.retag(file, with: Self.old)
    #expect(await AudioTags.read(from: file) == Self.old)
    // Put the extras in, then merge.
    try replaceWAVTag(file, with: tag(Self.old).serialized())
    _ = try await AudioRetagger.retag(file, with: Self.identified)

    expectMerged(await AudioTags.read(from: file), year: "1999")
    #expect(try chunk("data", of: file, bigEndian: false) == before)
    let data = try Data(contentsOf: file)
    #expect(data[4..<8].reversed().reduce(0) { $0 << 8 | Int($1) } == data.count - 8)
    expectExtras(ID3Tag.parse(try chunk("id3 ", of: file, bigEndian: false)))
    #expect(try Decoded(file).samples == Decoded(source).samples)
    try expectNoLeftovers()
  }

  @Test func damagedAIFFIsLeftAlone() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("cut.aiff")
    _ = try await AudioExporter.export(source, to: file, format: .aiff)
    let cut = try Data(contentsOf: file).prefix(50_000)
    try cut.write(to: file)
    await #expect(throws: AudioRetagError.self) { try await AudioRetagger.retag(file, with: Self.identified) }
    #expect(try Data(contentsOf: file) == cut)
    try expectNoLeftovers()
  }

  // MARK: FLAC

  @Test func flac() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("track.flac")
    _ = try await AudioExporter.export(source, to: file, format: .flac, tags: Self.old)
    // Add BPM and a back cover by hand.
    var data = try Data(contentsOf: file)
    let parsedBefore = try #require(FLACTags.blocks(in: data))
    var blocks = parsedBefore.blocks
    let vc = try #require(blocks.firstIndex { $0.type == 4 })
    let comment = try #require(FLACTags.parseVorbisComment(blocks[vc].body))
    blocks[vc].body = FLACTags.vorbisComment(vendor: comment.vendor, fields: comment.fields + ["BPM=128", "title=dupe"])
    var back = FLACTags.picture(Self.png, mime: "image/png")
    back.replaceSubrange(0..<4, with: bigEndian32(4))
    blocks.append(.init(type: 6, body: back))
    data = FLACTags.metadata(blocks) + data[parsedBefore.audioStart...]
    try data.write(to: file)
    let audioBefore = data[FLACTags.blocks(in: data)!.audioStart...]

    _ = try await AudioRetagger.retag(file, with: Self.identified)
    expectMerged(await AudioTags.read(from: file), year: "1999-03-22")
    let after = try Data(contentsOf: file)
    let parsed = try #require(FLACTags.blocks(in: after))
    #expect(after[parsed.audioStart...] == audioBefore)
    let fields = try #require(FLACTags.parseVorbisComment(parsed.blocks.first { $0.type == 4 }!.body)).fields
    #expect(fields.contains("BPM=128"))
    #expect(fields.filter { $0.uppercased().hasPrefix("TITLE=") } == ["TITLE=Windowlicker"])
    let pictures = parsed.blocks.filter { $0.type == 6 }.compactMap { FLACTags.parsePicture($0.body) }
    #expect(pictures.filter { $0.type == 3 }.map(\.data) == [Self.jpeg])
    #expect(pictures.filter { $0.type == 4 }.map(\.data) == [Self.png])
    #expect(try Decoded(file).samples == Decoded(source).samples)
    try expectNoLeftovers()
  }

  // MARK: MP3

  @Test func mp3v23() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("track.mp3")
    _ = try await AudioExporter.export(source, to: file, format: .mp3_320)
    let audio = try Data(contentsOf: file)
    try (tag(Self.old).serialized() + audio).write(to: file)
    let decodedBefore = try Decoded(file).samples

    _ = try await AudioRetagger.retag(file, with: Self.identified)
    expectMerged(await AudioTags.read(from: file), year: "1999")
    let after = try Data(contentsOf: file)
    #expect(after[3] == 3)
    let size = try #require(ID3Tag.totalSize(header: after))
    #expect(after[size...] == audio)
    expectExtras(ID3Tag.parse(after))
    #expect(try Decoded(file).samples == decodedBefore)
    try expectNoLeftovers()
  }

  /// v2.4 stays v2.4 (syncsafe frame sizes, full date in TDRC); a trailing ID3v1 tag is kept.
  @Test func mp3v24() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("track24.mp3")
    _ = try await AudioExporter.export(source, to: file, format: .mp3_256)
    var id3v1 = Data("TAG".utf8) + Data("Old v1 title".utf8)
    id3v1 += Data(repeating: 0, count: 128 - id3v1.count)
    let audio = try Data(contentsOf: file) + id3v1
    var old = tag(Self.old, major: 4)
    old.frames.append(.text("TDRC", "1990"))
    try (old.serialized() + audio).write(to: file)

    _ = try await AudioRetagger.retag(file, with: Self.identified)
    expectMerged(await AudioTags.read(from: file), year: "1999-03-22")
    let after = try Data(contentsOf: file)
    #expect(after[3] == 4)
    let size = try #require(ID3Tag.totalSize(header: after))
    #expect(after[size...] == audio)
    let parsed = try #require(ID3Tag.parse(after))
    expectExtras(parsed)
    #expect(parsed.frames.filter { $0.id == "TDRC" }.count == 1)
    // The GEOB's size is syncsafe on disk.
    let geob = try #require(after.range(of: Data("GEOB".utf8)))
    let stored = after[geob.upperBound..<geob.upperBound + 4]
    #expect(stored == ID3Tag.syncsafe(Self.geob.body.count))
    #expect(stored != bigEndian32(UInt32(Self.geob.body.count)))
    // AVFoundation agrees.
    let common = try await AVURLAsset(url: file).load(.commonMetadata)
    let title = try await AVMetadataItem.metadataItems(from: common, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common)
      .first?.load(.stringValue)
    #expect(title == "Windowlicker")
  }

  /// No tag: one is put in front; the rest of the file is the old file.
  @Test func mp3WithoutTag() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("bare.mp3")
    _ = try await AudioExporter.export(source, to: file, format: .mp3_192)
    let before = try Data(contentsOf: file)
    _ = try await AudioRetagger.retag(file, with: Self.identified)
    let after = try Data(contentsOf: file)
    let size = try #require(ID3Tag.totalSize(header: after))
    #expect(after[size...] == before)
    var expected = Self.identified
    expected.album = nil
    expected.year = "1999"
    #expect(await AudioTags.read(from: file) == expected)
  }

  /// Tag-level unsynchronisation is undone; frames survive and the tag comes back plain.
  @Test func mp3Unsynchronised() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("unsync.mp3")
    _ = try await AudioExporter.export(source, to: file, format: .mp3_192)
    let audio = try Data(contentsOf: file)
    let plain = [UInt8](tag(Self.old).serialized())
    var body: [UInt8] = []
    for byte in plain[10...] {
      body.append(byte)
      if byte == 0xFF { body.append(0) }
    }
    var unsynced = Data("ID3".utf8) + Data([3, 0, 0x80]) + ID3Tag.syncsafe(body.count)
    unsynced += Data(body)
    #expect(unsynced.count > plain.count)  // the GEOB has 0xFF in it
    try (unsynced + audio).write(to: file)

    #expect(await AudioTags.read(from: file).album == "Old Album")
    _ = try await AudioRetagger.retag(file, with: Self.identified)
    expectMerged(await AudioTags.read(from: file), year: "1999")
    let after = try Data(contentsOf: file)
    #expect(after[5] == 0)
    expectExtras(ID3Tag.parse(after))
    #expect(after[try #require(ID3Tag.totalSize(header: after))...] == audio)
  }

  // MARK: Moving, errors

  @Test func moveTo() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("unknown.aiff")
    _ = try await AudioExporter.export(source, to: file, format: .aiff, tags: Self.old)
    let destination = dir.appendingPathComponent("Sorted/Aphex Twin - Windowlicker.aiff")
    let result = try await AudioRetagger.retag(file, with: Self.identified, moveTo: destination)
    #expect(result == destination)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(await AudioTags.read(from: destination).title == "Windowlicker")
    try expectNoLeftovers()
  }

  @Test func caseOnlyRename() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("windowlicker.mp3")
    _ = try await AudioExporter.export(source, to: file, format: .mp3_192)
    let destination = dir.appendingPathComponent("Windowlicker.mp3")
    let result = try await AudioRetagger.retag(file, with: Self.identified, moveTo: destination)
    #expect(result == destination)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains("Windowlicker.mp3"))
    #expect(!names.contains("windowlicker.mp3"))
  }

  @Test func rawAACIsRefused() async throws {
    let file = dir.appendingPathComponent("rip.aac")
    let adts = Data([0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC] + Array(repeating: 0, count: 64))
    try adts.write(to: file)
    await #expect(throws: AudioRetagError.unsupported("Can't write tags into a raw AAC file.")) {
      try await AudioRetagger.retag(file, with: Self.identified)
    }
    #expect(try Data(contentsOf: file) == adts)
    try expectNoLeftovers()
  }

  @Test func otherFilesAreRefused() async throws {
    let file = dir.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)
    await #expect(throws: AudioRetagError.self) { try await AudioRetagger.retag(file, with: Self.identified) }
  }

  // MARK: M4A

  @Test func m4a() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let plain = dir.appendingPathComponent("plain.m4a")
    let file = dir.appendingPathComponent("track.m4a")
    try encodeAAC(source, to: plain)
    // Existing tags, including a BPM, via a passthrough export.
    try await passthrough(plain, to: file, metadata: [
      item(.iTunesMetadataSongName, "Unknown Track" as NSString), item(.iTunesMetadataAlbum, "Old Album" as NSString),
      item(.iTunesMetadataBeatsPerMin, NSNumber(value: 128), type: kCMMetadataBaseDataType_SInt16 as String),
    ])
    let before = try await packets(file)
    #expect(before.count > 20_000)  // ≈ 1 s at 192 kbps

    _ = try await AudioRetagger.retag(file, with: Self.identified)
    expectMerged(await AudioTags.read(from: file), year: "1999-03-22")
    let items = try await AVURLAsset(url: file).load(.metadata)
    let bpm = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataBeatsPerMin).first
    #expect(try await bpm?.load(.numberValue)?.intValue == 128)
    #expect(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataSongName).count == 1)
    // Not re-encoded: the same AAC packets.
    #expect(try await packets(file) == before)
    #expect(try Decoded(file).frames == 44_100)
    try expectNoLeftovers()
  }

  // MARK: Export, reading

  @Test(arguments: [AudioFileFormat.aiff, .flac, .mp3_320])
  func exportWritesEveryField(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("all.\(format.fileExtension)")
    var tags = Self.identified
    tags.album = "Old Album"
    _ = try await AudioExporter.export(source, to: out, format: format, tags: tags)
    expectMerged(await AudioTags.read(from: out), year: format == .flac ? "1999-03-22" : "1999")
  }

  @Test func genres() {
    #expect(ID3Tag.genreName("(17)") == "Rock")
    #expect(ID3Tag.genreName("(31)Trance") == "Trance")
    #expect(ID3Tag.genreName("35") == "House")
    #expect(ID3Tag.genreName("Tech House") == "Tech House")
    #expect(ID3Tag.genreName("((Bracketed)") == "(Bracketed)")
  }

  // MARK: Helpers

  func chunk(_ id: String, of url: URL, bigEndian: Bool) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let layout = try TagFile.chunks(handle, bigEndian: bigEndian)
    let chunk = try #require(layout.chunks.first { $0.name == id })
    try handle.seek(toOffset: chunk.dataOffset)
    return try handle.read(upToCount: Int(chunk.size)) ?? Data()
  }

  /// Swaps the WAV's "id3 " chunk for `tag` (by hand, not with the code under test).
  func replaceWAVTag(_ url: URL, with tag: Data) throws {
    let handle = try FileHandle(forReadingFrom: url)
    let layout = try TagFile.chunks(handle, bigEndian: false)
    try handle.close()
    let data = try Data(contentsOf: url)
    var out = Data(data.prefix(12))
    for chunk in layout.chunks where !chunk.isID3 {
      out += data[Int(chunk.offset)..<Int(chunk.dataOffset + chunk.size + chunk.size % 2)]
    }
    out += Data("id3 ".utf8) + littleEndian32(UInt32(tag.count)) + tag
    if tag.count % 2 == 1 { out.append(0) }
    out.replaceSubrange(4..<8, with: littleEndian32(UInt32(out.count - 8)))
    try out.write(to: url)
  }

  func encodeAAC(_ source: URL, to url: URL) throws {
    let input = try AVAudioFile(forReading: source)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
    ]
    let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
    try input.read(into: buffer)
    try output.write(from: buffer)
  }

  func item(
    _ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, type: String = kCMMetadataBaseDataType_UTF8 as String
  ) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value
    item.dataType = type
    return item
  }

  /// The compressed audio, packet bytes back to back.
  func packets(_ url: URL) async throws -> Data {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var out = Data()
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var bytes = Data(count: CMBlockBufferGetDataLength(block))
      bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
      out += bytes
    }
    #expect(reader.status == .completed)
    return out
  }

  func passthrough(_ source: URL, to url: URL, metadata: [AVMetadataItem]) async throws {
    let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
    session.outputURL = url
    session.outputFileType = .m4a
    session.metadata = metadata
    nonisolated(unsafe) let s = session
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in s.exportAsynchronously { done.resume() } }
    #expect(session.status == .completed, "\(session.error as Any)")
  }
}

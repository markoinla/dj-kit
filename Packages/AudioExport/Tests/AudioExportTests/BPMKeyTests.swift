import AVFoundation
import Foundation
import Testing
@testable import AudioExport

/// BPM and key: written by the exporter, merged by the retagger, read from
/// tags other software wrote (raw frames built by hand).
extension AudioRetaggerTests {
  static let analysed = AudioTags(bpm: " 123.5 ", key: "8A")

  // MARK: Export

  @Test(arguments: [AudioFileFormat.aiff, .flac, .mp3_320])
  func exportWritesBPMAndKey(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("bpm.\(format.fileExtension)")
    var tags = Self.old
    tags.bpm = Self.analysed.bpm
    tags.key = Self.analysed.key
    _ = try await AudioExporter.export(source, to: out, format: format, tags: tags)
    let read = await AudioTags.read(from: out)
    #expect(read.bpm == "123.5")
    #expect(read.key == "8A")
    #expect(read.title == "Unknown Track")
    #expect(read.artwork == Self.png)

    switch format {
    case .flac:
      let fields = try vorbisFields(out)
      #expect(fields.contains("BPM=123.5"))
      #expect(fields.contains("INITIALKEY=8A"))
    case .aiff:
      let tag = try #require(ID3Tag.parse(try chunk("ID3 ", of: out, bigEndian: true)))
      #expect(tag.frames.map(\.id).contains("TBPM"))
      #expect(tag.frames.map(\.id).contains("TKEY"))
    default:
      let tag = try #require(ID3Tag.parse(try Data(contentsOf: out)))
      #expect(tag.major == 3)
      #expect(tag.frames.filter { $0.id == "TBPM" }.count == 1)
      #expect(tag.frames.filter { $0.id == "TKEY" }.count == 1)
    }
  }

  /// Blank BPM / key count as missing: nothing written.
  @Test(arguments: [AudioFileFormat.aiff, .flac])
  func blankBPMAndKeyAreNotWritten(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let out = dir.appendingPathComponent("blank.\(format.fileExtension)")
    _ = try await AudioExporter.export(source, to: out, format: format, tags: AudioTags(title: "T", bpm: "", key: "  "))
    let read = await AudioTags.read(from: out)
    #expect(read == AudioTags(title: "T"))
  }

  @Test func bpmAndKeyCount() {
    #expect(!AudioTags(bpm: "124").isEmpty)
    #expect(!AudioTags(key: "8A").isEmpty)
    #expect(AudioTags(bpm: "124") != AudioTags(bpm: "125"))
    #expect(AudioTags(bpm: "124", key: "8A").suffixingTitle(" (Vocals)", fallbackTitle: "x")
      == AudioTags(title: "x (Vocals)", bpm: "124", key: "8A"))
  }

  // MARK: Retag

  /// BPM / key only: added where missing, replaced in place where present, and
  /// every other frame comes back byte for byte in the same order.
  @Test(arguments: [AudioFileFormat.aiff, .wav, .mp3_320])
  func retagMergesBPMAndKeyOnly(format: AudioFileFormat) async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("retag.\(format.fileExtension)")
    _ = try await AudioExporter.export(source, to: file, format: format)

    // No BPM / key yet: added at the end.
    var plain = ID3Tag()
    plain.merge(Self.old)
    try storeTag(plain, in: file, format: format)
    let audio = try audioBytes(file, format: format)
    _ = try await AudioRetagger.retag(file, with: AudioTags(bpm: "124", key: "9A"))
    var tag = try storedTag(file, format: format)
    #expect(tag.frames.map(\.id) == plain.frames.map(\.id) + ["TBPM", "TKEY"])
    #expect(zip(tag.frames, plain.frames).allSatisfy { $0.body == $1.body })
    var read = await AudioTags.read(from: file)
    #expect(read.bpm == "124")
    #expect(read.key == "9A")
    #expect(read.title == "Unknown Track")

    // Existing frames (with the extras): only TBPM changes, in place; nil key leaves TKEY.
    let old = self.tag(Self.old)
    try storeTag(old, in: file, format: format)
    _ = try await AudioRetagger.retag(file, with: AudioTags(bpm: "123.5"))
    tag = try storedTag(file, format: format)
    #expect(tag.frames.map(\.id) == old.frames.map(\.id))
    for (new, before) in zip(tag.frames, old.frames) where new.id != "TBPM" {
      #expect(new.body == before.body, "\(new.id) changed")
    }
    read = await AudioTags.read(from: file)
    #expect(read.bpm == "123.5")
    #expect(read.key == "8A")
    #expect(read.album == "Old Album")
    #expect(try audioBytes(file, format: format) == audio)
    try expectNoLeftovers()
  }

  @Test func retagFLACMergesBPMAndKeyOnly() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("retag.flac")
    _ = try await AudioExporter.export(source, to: file, format: .flac, tags: Self.old)
    let audio = try audioBytes(file, format: .flac)

    _ = try await AudioRetagger.retag(file, with: AudioTags(bpm: "124", key: "9A"))
    let first = try vorbisFields(file)
    #expect(first.suffix(2) == ["BPM=124", "INITIALKEY=9A"])

    // A foreign TEMPO / key comment is replaced in place; nil key leaves INITIALKEY.
    try setVorbisFields(file, ["TITLE=Unknown Track", "tempo=128", "Comment=keep me", "INITIALKEY=9A"])
    _ = try await AudioRetagger.retag(file, with: AudioTags(bpm: "125"))
    #expect(try vorbisFields(file) == ["TITLE=Unknown Track", "BPM=125", "Comment=keep me", "INITIALKEY=9A"])
    let read = await AudioTags.read(from: file)
    #expect(read.bpm == "125")
    #expect(read.key == "9A")
    #expect(read.artwork == Self.png)
    #expect(try audioBytes(file, format: .flac) == audio)
    try expectNoLeftovers()
  }

  @Test func m4aBPMAndKey() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let plain = dir.appendingPathComponent("plain.m4a")
    let file = dir.appendingPathComponent("key.m4a")
    try encodeAAC(source, to: plain)
    try await passthrough(plain, to: file, metadata: [
      item(.iTunesMetadataSongName, "Unknown Track" as NSString),
      item(.iTunesMetadataBeatsPerMin, NSNumber(value: 128), type: kCMMetadataBaseDataType_SInt16 as String),
      item(M4AKeys.initialKey, "8A" as NSString),
    ])
    var read = await AudioTags.read(from: file)
    #expect(read.bpm == "128")
    #expect(read.key == "8A")
    let before = try await packets(file)

    _ = try await AudioRetagger.retag(file, with: AudioTags(bpm: "123.6", key: "9A"))
    read = await AudioTags.read(from: file)
    #expect(read.bpm == "124")
    #expect(read.key == "9A")
    #expect(read.title == "Unknown Track")
    let items = try await AVURLAsset(url: file).load(.metadata)
    #expect(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataBeatsPerMin).count == 1)
    #expect(try await packets(file) == before)
    try expectNoLeftovers()
  }

  // MARK: Reading other software's tags

  /// v2.4 (syncsafe sizes, UTF-8, two values in one frame), v2.3 (UTF-16 with BOM)
  /// and v2.2 (TBP / TKE, 3-byte sizes), as Rekordbox, Traktor and old iTunes write them.
  @Test func readsForeignID3Frames() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let mp3 = dir.appendingPathComponent("bare.mp3")
    _ = try await AudioExporter.export(source, to: mp3, format: .mp3_192)
    let audio = try Data(contentsOf: mp3)

    func v23or24(major: UInt8, _ frames: [(String, [UInt8])]) -> Data {
      var body = Data()
      for (id, bytes) in frames {
        body += Data(id.utf8)
        body += major == 4 ? ID3Tag.syncsafe(bytes.count) : bigEndian32(UInt32(bytes.count))
        body += Data([0, 0]) + Data(bytes)
      }
      return Data("ID3".utf8) + Data([major, 0, 0]) + ID3Tag.syncsafe(body.count) + body
    }
    func utf16(_ s: String) -> [UInt8] { [0xFF, 0xFE] + s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }

    let cases: [(name: String, tag: Data, bpm: String, key: String)] = [
      ("v24", v23or24(major: 4, [
        ("TIT2", [3] + Array("Title".utf8)),
        ("TBPM", [3] + Array("126".utf8)),
        ("TKEY", [3] + Array("F#m".utf8) + [0] + Array("11A".utf8)),
      ]), "126", "F#m; 11A"),
      ("v23", v23or24(major: 3, [
        ("TBPM", [0] + Array("128.00".utf8) + [0]),
        ("TKEY", [1] + utf16("D♭")),
      ]), "128.00", "D♭"),
      ("v22", {
        var body = Data()
        for (id, text) in [("TT2", "Title"), ("TBP", "122"), ("TKE", "Ebm")] {
          let bytes = [UInt8(0)] + Array(text.utf8)
          body += Data(id.utf8) + Data([0, 0, UInt8(bytes.count)]) + Data(bytes)
        }
        return Data("ID3".utf8) + Data([2, 0, 0]) + ID3Tag.syncsafe(body.count) + body
      }(), "122", "Ebm"),
    ]
    for c in cases {
      let file = dir.appendingPathComponent("\(c.name).mp3")
      try (c.tag + audio).write(to: file)
      let read = await AudioTags.read(from: file)
      #expect(read.bpm == c.bpm, "\(c.name)")
      #expect(read.key == c.key, "\(c.name)")
    }

    // The same v2.4 tag in an AIFF's ID3 chunk.
    let aiff = dir.appendingPathComponent("foreign.aiff")
    _ = try await AudioExporter.export(source, to: aiff, format: .aiff)
    try AudioExporter.appendAIFFID3Chunk(cases[0].tag, to: aiff)
    let read = await AudioTags.read(from: aiff)
    #expect(read.bpm == "126")
    #expect(read.title == "Title")

    // v2.2 comes back as v2.3 with TBPM / TKEY after a retag.
    let v22 = dir.appendingPathComponent("v22.mp3")
    _ = try await AudioRetagger.retag(v22, with: AudioTags(comment: "x"))
    let after = try #require(ID3Tag.parse(try Data(contentsOf: v22)))
    #expect(after.major == 3)
    #expect(after.audioTags.bpm == "122")
    #expect(after.audioTags.key == "Ebm")
  }

  @Test func readsVorbisKeyAndFallbacks() async throws {
    let source = try Synth.wav24(in: dir, seconds: 1)
    let file = dir.appendingPathComponent("vorbis.flac")
    _ = try await AudioExporter.export(source, to: file, format: .flac)

    try setVorbisFields(file, ["TITLE=x", "initialkey=Am", "BPM=124", "TEMPO=99", "KEY=C"])
    var read = await AudioTags.read(from: file)
    #expect(read.key == "Am")
    #expect(read.bpm == "124")

    try setVorbisFields(file, ["TEMPO=126", "Key=6A"])
    read = await AudioTags.read(from: file)
    #expect(read.bpm == "126")
    #expect(read.key == "6A")

    try setVorbisFields(file, ["BPM= ", "INITIALKEY="])
    read = await AudioTags.read(from: file)
    #expect(read.bpm == nil)
    #expect(read.key == nil)
  }

  // MARK: Helpers

  func vorbisFields(_ url: URL) throws -> [String] {
    let parsed = try #require(FLACTags.blocks(in: try Data(contentsOf: url)))
    let block = try #require(parsed.blocks.first { $0.type == 4 })
    return try #require(FLACTags.parseVorbisComment(block.body)).fields
  }

  /// Replaces the FLAC's Vorbis comments with `fields` (by hand).
  func setVorbisFields(_ url: URL, _ fields: [String]) throws {
    let data = try Data(contentsOf: url)
    let parsed = try #require(FLACTags.blocks(in: data))
    var blocks = parsed.blocks.filter { $0.type != 4 }
    blocks.insert(.init(type: 4, body: FLACTags.vorbisComment(vendor: "other", fields: fields)), at: 1)
    try (FLACTags.metadata(blocks) + data[parsed.audioStart...]).write(to: url)
  }

  /// Puts `tag` into the file in place of whatever it had (by hand).
  func storeTag(_ tag: ID3Tag, in url: URL, format: AudioFileFormat) throws {
    switch format {
    case .aiff:
      let data = try Data(contentsOf: url)
      let handle = try FileHandle(forReadingFrom: url)
      let layout = try TagFile.chunks(handle, bigEndian: true)
      try handle.close()
      var out = Data(data.prefix(12))
      for chunk in layout.chunks where !chunk.isID3 {
        out += data[Int(chunk.offset)..<Int(chunk.dataOffset + chunk.size + chunk.size % 2)]
      }
      out.replaceSubrange(4..<8, with: bigEndian32(UInt32(out.count - 8)))
      try out.write(to: url)
      try AudioExporter.appendAIFFID3Chunk(tag.serialized(), to: url)
    case .wav:
      try replaceWAVTag(url, with: tag.serialized())
    default:
      let data = try Data(contentsOf: url)
      let start = ID3Tag.totalSize(header: data) ?? 0
      try (tag.serialized() + data[start...]).write(to: url)
    }
  }

  func storedTag(_ url: URL, format: AudioFileFormat) throws -> ID3Tag {
    switch format {
    case .aiff: try #require(ID3Tag.parse(try chunk("ID3 ", of: url, bigEndian: true)))
    case .wav: try #require(ID3Tag.parse(try chunk("id3 ", of: url, bigEndian: false)))
    default: try #require(ID3Tag.parse(try Data(contentsOf: url)))
    }
  }

  /// The audio as stored: SSND / data chunk, MP3 frames after the tag, FLAC frames.
  func audioBytes(_ url: URL, format: AudioFileFormat) throws -> Data {
    switch format {
    case .aiff: return try chunk("SSND", of: url, bigEndian: true)
    case .wav: return try chunk("data", of: url, bigEndian: false)
    case .flac:
      let data = try Data(contentsOf: url)
      return data[try #require(FLACTags.blocks(in: data)).audioStart...]
    default:
      let data = try Data(contentsOf: url)
      return data[(ID3Tag.totalSize(header: data) ?? 0)...]
    }
  }
}

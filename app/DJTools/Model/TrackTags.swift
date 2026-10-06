import AudioExport
import Foundation

/// The tags and names a track's files carry: the file's own tags, with Track
/// ID's match over them when there is one (and it wasn't turned down).
enum TrackTags {
    /// "Artist - Title" when both are known, else `fallback` (the file name).
    static func displayName(_ tags: AudioTags, fallback: String) -> String {
        guard let artist = tags.artist?.trimmed, !artist.isEmpty,
              let title = tags.title?.trimmed, !title.isEmpty else { return fallback }
        return "\(artist) - \(title)"
    }

    /// `name` as a file name: no "/" or ":" (Finder's separators), no
    /// leading dot, trimmed, at most 200 characters.
    static func fileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.components(separatedBy: .newlines).joined(separator: " ").trimmed
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)).trimmed }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// The match as tags, its artwork downloaded (left out when that fails).
    static func tags(for identity: DJTrackIdentity) async -> AudioTags {
        var tags = AudioTags(title: identity.title, artist: identity.artist, album: identity.album)
        tags.genre = identity.genre
        tags.year = identity.releaseDate
        tags.label = identity.label
        tags.isrc = identity.isrc
        tags.artwork = await artwork(from: identity.artworkURL)
        return tags
    }

    /// What a tool's results are tagged with: the file's tags, and a match
    /// that's waiting or applied on top (an applied one is in the file
    /// already, but this also keeps fields AVFoundation can't read back).
    static func forResults(_ track: Track) async -> AudioTags {
        var tags = await AudioTags.read(from: track.url)
        guard let identity = track.identity, track.identityStatus != .dismissed else { return tags }
        let matched = await self.tags(for: identity)
        tags.title = matched.title
        tags.artist = matched.artist
        tags.album = matched.album ?? tags.album
        tags.genre = matched.genre ?? tags.genre
        tags.year = matched.year ?? tags.year
        tags.label = matched.label ?? tags.label
        tags.isrc = matched.isrc ?? tags.isrc
        tags.artwork = matched.artwork ?? tags.artwork
        return tags
    }

    /// `tags` with BPM and key from the track's analysis where `existing`
    /// (the file's own tags) has none: existing tags always win. BPM is
    /// folded for the track's genre and left out when the tempo isn't
    /// steady; the key is spelled as Settings ▸ Analysis says.
    static func fillingAnalysis(_ tags: AudioTags, from track: Track, keyTag: KeyTagStyle, existing: AudioTags) -> AudioTags {
        var filled = tags
        guard let analysis = track.analysis else { return filled }
        if !AudioTags.hasBPM(existing.bpm), let tempo = analysis.tempo, tempo.isSteady, let bpm = track.detectedBPM {
            filled.bpm = DJBPM.string(bpm)
        }
        if existing.key?.trimmed.isEmpty ?? true, let key = analysis.key?.key {
            filled.key = keyTag == .camelot ? key.camelot : key.musical
        }
        return filled
    }

    /// JPEG or PNG bytes from `url`, or nil.
    static func artwork(from url: URL?) async -> Data? {
        guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return data
    }
}

extension AudioTags {
    /// A BPM tag as a number; nil when missing, zero or not a number.
    static func bpmValue(_ text: String?) -> Double? {
        guard let value = text.flatMap({ Double($0.trimmed) }), value > 0 else { return nil }
        return value
    }

    /// Any BPM text but "0" counts as a tag (never overwritten).
    static func hasBPM(_ text: String?) -> Bool {
        guard let text = text?.trimmed, !text.isEmpty else { return false }
        return Double(text) != 0
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

@preconcurrency import AVFoundation
import Foundation
import MusicKit
import ShazamKit

/// Track ID: ShazamKit listens to a few short windows of the file (the
/// fingerprints are made on this Mac; only they go to Apple), the windows
/// vote, and the Apple Music catalog fills in album, label, release date and
/// artwork. When the song has several releases, the one whose length is
/// closest to the file wins (an extended mix over the radio edit).
///
/// Ported from Wax Studio's `ShazamIdentifier` and `CatalogEnricher`, cut
/// down to one track per file. Needs the ShazamKit and MusicKit App Services on the App ID
/// `la.marko.djtools` and a team-signed build; catalog reads need no Apple
/// Music subscription.
struct ShazamTrackIdentifier: TrackIdentifying {
    /// ShazamKit's catalog takes at most 12 s per signature.
    static let windowSeconds: TimeInterval = 12
    /// Where the listens start, as fractions of the track: past the intro,
    /// before the outro (often just drums for mixing).
    static let positions: [Double] = [0.3, 0.5, 0.7]

    /// SHSignatureGenerator takes PCM at 48, 44.1, 32 or 16 kHz; mono keeps signatures small.
    private static let signatureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!

    func identify(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> DJTrackIdentity? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppError("Couldn't read the file: \(error.localizedDescription)")
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard let converter = AVAudioConverter(from: file.processingFormat, to: Self.signatureFormat) else {
            throw AppError("Couldn't convert the audio for listening.")
        }
        let length = min(Self.windowSeconds, duration)
        let starts = duration <= Self.windowSeconds * 2
            ? [0]
            : Self.positions.map { min($0 * duration, duration - length) }

        // Listening is most of the work; the catalog the rest.
        let session = SHSession()
        var matches: [SHMatchedMediaItem] = []
        var errors: [String] = []
        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            do {
                let signature = try Self.signature(of: file, from: start, seconds: length, converter: converter)
                switch await session.result(from: signature) {
                case .match(let match):
                    if let item = match.mediaItems.first { matches.append(item) }
                case .noMatch:
                    break
                case .error(let error, _):
                    errors.append(Self.describe(error))
                @unknown default:
                    errors.append("Shazam gave an unknown result.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errors.append(error.localizedDescription)
            }
            progress(0.8 * Double(index + 1) / Double(starts.count))
        }
        try Task.checkCancellation()
        if matches.isEmpty, errors.count == starts.count, let first = errors.first {
            throw AppError(first)
        }

        // The song most listens agree on (the earliest listen breaks a tie).
        let groups = Dictionary(grouping: matches, by: Self.songKey)
        guard let best = groups.values.max(by: { a, b in
            a.count != b.count ? a.count < b.count : Self.firstIndex(of: a, in: matches) > Self.firstIndex(of: b, in: matches)
        }), let lead = best.first else {
            progress(1)
            return nil
        }

        var identity = DJTrackIdentity(
            title: lead.title ?? "Unknown", artist: lead.artist ?? "Unknown",
            genre: lead.genres.first, isrc: lead.isrc,
            artworkURL: lead.artworkURL, appleMusicURL: lead.appleMusicURL, shazamURL: lead.webURL,
            hits: best.count, listens: starts.count
        )
        if let release = await Self.catalogRelease(of: best, fileDuration: duration) {
            identity.title = release.title
            identity.artist = release.artistName
            identity.album = release.albumTitle ?? release.albums?.first?.title
            identity.label = release.albums?.first?.recordLabelName
            identity.genre = release.genreNames.first { $0 != "Music" } ?? identity.genre
            identity.releaseDate = (release.releaseDate ?? release.albums?.first?.releaseDate).map(Self.formatDate)
            identity.isrc = release.isrc ?? identity.isrc
            identity.durationSeconds = release.duration
            identity.artworkURL = release.artwork?.url(width: 1400, height: 1400) ?? identity.artworkURL
            identity.appleMusicURL = release.url ?? identity.appleMusicURL
        }
        progress(1)
        return identity
    }

    // MARK: - Listening

    /// Fingerprints one window. Local only.
    private static func signature(
        of file: AVAudioFile, from start: TimeInterval, seconds: TimeInterval, converter: AVAudioConverter
    ) throws -> SHSignature {
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AppError("Couldn't convert the audio for listening.")
        }
        file.framePosition = AVAudioFramePosition(start * format.sampleRate)
        try file.read(into: pcm, frameCount: frames)

        converter.reset()
        let ratio = signatureFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let mono = AVAudioPCMBuffer(pcmFormat: signatureFormat, frameCapacity: capacity) else {
            throw AppError("Couldn't convert the audio for listening.")
        }
        let source = OneShotBuffer(pcm)
        var conversionError: NSError?
        let status = converter.convert(to: mono, error: &conversionError) { _, inputStatus in
            guard let buffer = source.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || conversionError != nil { throw AppError("Couldn't convert the audio for listening.") }

        let generator = SHSignatureGenerator()
        try generator.append(mono, at: nil)
        return generator.signature()
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SHErrorDomain, SHError.Code(rawValue: ns.code) == .matchAttemptFailed {
            return "Shazam couldn't be reached. Check the internet connection."
        }
        return error.localizedDescription
    }

    /// Same song, any release: artist and title without the version in
    /// brackets or after " - " (Remastered, Extended Mix, Radio Edit…), so
    /// listens that hit different releases still vote together. The catalog
    /// then picks the release that fits the file.
    private static func songKey(_ item: SHMatchedMediaItem) -> String {
        func base(_ text: String?) -> String {
            var t = (text ?? "").lowercased()
            t = t.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        return "\(base(item.artist))|\(base(item.title))"
    }

    private static func firstIndex(of group: [SHMatchedMediaItem], in all: [SHMatchedMediaItem]) -> Int {
        all.firstIndex { $0 === group.first } ?? .max
    }

    // MARK: - Catalog

    /// Every release the listens matched (by Apple Music ID, else ISRC),
    /// looked up in the catalog; the one closest in length to the file wins,
    /// the earliest release on a tie. Nil when nothing could be looked up
    /// (no IDs, offline, MusicKit not allowed): the Shazam fields stand.
    private static func catalogRelease(of items: [SHMatchedMediaItem], fileDuration: TimeInterval) async -> Song? {
        if MusicAuthorization.currentStatus == .notDetermined {
            _ = await MusicAuthorization.request()
        }
        var seen = Set<String>()
        var songs: [Song] = []
        for item in items {
            let key = item.appleMusicID ?? item.isrc ?? ""
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            var request: MusicCatalogResourceRequest<Song>
            if let id = item.appleMusicID, !id.isEmpty {
                request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            } else if let isrc = item.isrc {
                request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
            } else {
                continue
            }
            request.properties = [.albums]
            if let found = try? await request.response().items {
                songs.append(contentsOf: found.prefix(3))
            }
        }
        return songs.min { a, b in
            let da = a.duration.map { abs($0 - fileDuration) } ?? .infinity
            let db = b.duration.map { abs($0 - fileDuration) } ?? .infinity
            if abs(da - db) > 2 { return da < db }
            return (a.releaseDate ?? .distantFuture) < (b.releaseDate ?? .distantFuture)
        }
    }

    private static func formatDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Hands its buffer out once, then nil: the AVAudioConverter input block.
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

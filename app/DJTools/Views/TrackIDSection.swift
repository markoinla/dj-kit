import AppKit
import SwiftUI

/// Track ID for one track: listening, the match to Apply (or turn down),
/// what was applied, or that nothing matched.
struct TrackIDSection: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let job: Job?

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.sm) {
            DJSectionHeader(title: "Track ID") {
                if job?.state.isActive != true, track.fileExists, track.identifiedAt != nil || track.identifyError != nil {
                    DJLinkButton("Identify Again") { model.identify([track.id]) }
                }
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if job?.state.isActive == true {
            VStack(alignment: .leading, spacing: DJSpace.sm) {
                Text("Listening…").djText(.bodyMedium).foregroundStyle(DJColor.foreground)
                DJProgressBar(fraction: job?.progress, height: 4)
                    .frame(maxWidth: 240)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .djCard(padding: DJSpace.lg)
        } else if let error = track.identifyError {
            DJNotice(kind: .error, message: "Couldn't identify: \(error)")
        } else if let identity = track.identity, track.identityStatus != .dismissed {
            IdentityCard(track: track, identity: identity, applying: model.applying.contains(track.id),
                         renames: model.settings.renameOnApply)
        } else if track.identifiedAt != nil {
            Text(track.identityStatus == .dismissed ? "Match turned down" : "No match")
                .djText(.body)
                .foregroundStyle(DJColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .djCard(padding: DJSpace.lg)
        } else {
            HStack {
                Text("Not identified")
                    .djText(.body)
                    .foregroundStyle(DJColor.mutedForeground)
                Spacer()
                Button("Identify", systemImage: "shazam.logo") { model.identify([track.id]) }
                    .buttonStyle(.dj(.outline, size: .small))
                    .disabled(!track.fileExists)
            }
            .djCard(padding: DJSpace.lg)
        }
    }
}

private struct IdentityCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let identity: DJTrackIdentity
    let applying: Bool
    let renames: Bool

    private var isApplied: Bool { track.identityStatus == .applied }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DJSpace.lg) {
                Artwork(url: identity.artworkURL)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: DJSpace.sm) {
                        Text(identity.title)
                            .djText(.headline)
                            .foregroundStyle(DJColor.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DJSpace.sm)
                        badge
                    }
                    Text(identity.artist)
                        .djText(.body)
                        .foregroundStyle(DJColor.foreground)
                    if !details.isEmpty {
                        Text(details)
                            .djText(.caption)
                            .foregroundStyle(DJColor.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: DJSpace.md) {
                        Text("\(identity.hits)/\(identity.listens) listens")
                        if let url = identity.appleMusicURL { Link("Apple Music", destination: url) }
                        if let url = identity.shazamURL { Link("Shazam", destination: url) }
                    }
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .padding(.top, 2)
                }
            }
            .padding(DJSpace.lg)

            if track.identityLengthMismatch, let expected = identity.durationSeconds, let actual = track.quality?.duration {
                Label("Release is \(DJFormat.duration(expected)), file is \(DJFormat.duration(actual)): maybe another mix",
                      systemImage: "exclamationmark.triangle")
                    .djText(.caption)
                    .foregroundStyle(DJColor.marker)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DJSpace.lg)
                    .padding(.bottom, DJSpace.md)
            } else if !identity.isStrong, !isApplied {
                Label("Weak match", systemImage: "questionmark.circle")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .padding(.horizontal, DJSpace.lg)
                    .padding(.bottom, DJSpace.md)
            }

            if !isApplied {
                DJDivider()
                HStack(spacing: DJSpace.md) {
                    Text(applyNote)
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: DJSpace.md)
                    Button("Not This Track") { model.dismissIdentity([track.id]) }
                        .buttonStyle(.dj(.ghost, size: .small))
                        .disabled(applying)
                    Button(applying ? "Applying…" : "Apply", systemImage: "checkmark") { model.applyIdentity([track.id]) }
                        .buttonStyle(.dj(.primary, size: .small))
                        .disabled(applying || !track.fileExists)
                }
                .padding(.horizontal, DJSpace.lg)
                .padding(.vertical, DJSpace.md)
            }
        }
        .djCard()
    }

    @ViewBuilder private var badge: some View {
        if isApplied {
            Label("Applied", systemImage: "checkmark.circle.fill")
                .font(.dj(11, weight: 600))
                .foregroundStyle(DJColor.success)
                .fixedSize()
        }
    }

    /// "Album · Label · 2024 · House".
    private var details: String {
        [identity.album, identity.label, identity.year, identity.genre].compactMap { $0 }.joined(separator: " · ")
    }

    private var applyNote: String {
        let name = TrackTags.fileName("\(identity.artist) - \(identity.title)") + "." + track.url.pathExtension
        return renames && name != track.url.lastPathComponent ? "Tags + rename to “\(name)”" : "Writes tags + artwork"
    }
}

/// The release's cover, or a placeholder tile.
private struct Artwork: View {
    let url: URL?
    private let size: CGFloat = 72

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    DJColor.muted
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(DJColor.mutedForeground)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DJRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DJRadius.md).strokeBorder(DJColor.border))
        .accessibilityHidden(true)
    }
}

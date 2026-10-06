#if DEBUG
import AppKit
import AudioExport
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `-renderPreviews <dir>`: draws the main screens with fixture data to
/// PNGs via `ImageRenderer`, no window or GUI session needed, then exits.
///
/// `ImageRenderer` can't draw AppKit-backed views (List, ScrollView, Form,
/// sheets), so each screen is the app's own content views laid out in a
/// stand-in window: the sidebar's rows in a plain stack, the detail without
/// its scroll view, the sheet over a dimmed window.
@MainActor
enum PreviewRenderer {
    static let size = CGSize(width: 1180, height: 760)

    static func run(into directory: URL) {
        FileCheck.assumeExists = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = PreviewFixtures()

        let empty = fixtures.model(tracks: [], jobs: [])
        let busy = fixtures.model(tracks: fixtures.tracks, jobs: fixtures.liveJobs)
        let queue = fixtures.model(tracks: fixtures.tracks, jobs: fixtures.queueJobs, showsJobs: true)
        let installing = fixtures.model(tracks: fixtures.tracks, jobs: fixtures.liveJobs,
                                        apollo: .installing("Downloading the repair model (66 MB)"))
        let repairing = fixtures.model(tracks: fixtures.tracks, jobs: fixtures.repairJobs, apollo: .ready, showsJobs: true)
        // Settings say stems as FLAC and repairs as MP3 320: the format menus and the MP3 hint.
        let repairAsMP3 = fixtures.model(tracks: fixtures.tracks, jobs: [], apollo: .ready, settings: fixtures.mp3Settings)

        var shots: [(String, AnyView)] = [
            ("01-welcome", AnyView(PreviewWindow(model: empty, selection: []))),
            ("02-track-low-quality", AnyView(PreviewWindow(model: busy, selection: [fixtures.overmono.id]))),
            ("03-track-lossless-results", AnyView(PreviewWindow(model: busy, selection: [fixtures.floatingPoints.id]))),
            ("04-multi-select", AnyView(PreviewWindow(model: busy, selection: [fixtures.overmono.id, fixtures.fred.id, fixtures.ross.id]))),
            ("05-queue", AnyView(PreviewWindow(model: queue, selection: [fixtures.bicep.id]))),
            ("06-apollo-setup", AnyView(PreviewWindow(model: busy, selection: [fixtures.overmono.id],
                                                      sheet: AnyView(ApolloSetupContent(state: .notInstalled, trackCount: 1))))),
            ("07-apollo-installing", AnyView(PreviewWindow(model: installing, selection: [fixtures.overmono.id],
                                                           sheet: AnyView(ApolloSetupContent(state: installing.apolloState, trackCount: 1))))),
            ("08-track-checking", AnyView(PreviewWindow(model: busy, selection: [fixtures.kettama.id]))),
            ("09-track-very-low-source", AnyView(PreviewWindow(model: repairing, selection: [fixtures.burial.id]))),
            ("10-track-repair-as-mp3", AnyView(PreviewWindow(model: repairAsMP3, selection: [fixtures.bicep.id]))),
        ]
        // Normalize Loudness: measured (−6.2 → −10.0 LUFS) and capped by the ceiling, in a taller window.
        let normalizing = fixtures.model(tracks: fixtures.tracks, jobs: fixtures.normalizeJobs, apollo: .ready, showsJobs: true)
        let tall: [(String, AnyView)] = [
            ("15-normalize-measured", AnyView(PreviewWindow(model: busy, selection: [fixtures.ross.id]))),
            ("16-normalize-capped", AnyView(PreviewWindow(model: busy, selection: [fixtures.floatingPoints.id]))),
            ("17-normalize-running", AnyView(PreviewWindow(model: normalizing, selection: [fixtures.bicep.id]))),
            ("18-normalize-multi", AnyView(PreviewWindow(model: busy, selection: [fixtures.floatingPoints.id, fixtures.ross.id, fixtures.fred.id, fixtures.bicep.id]))),
            ("19-dark-normalize-capped", AnyView(PreviewWindow(model: busy, selection: [fixtures.floatingPoints.id]))),
        ]
        shots.append(contentsOf: [
            ("11-dark-track-low-quality", AnyView(PreviewWindow(model: busy, selection: [fixtures.overmono.id]))),
            ("12-dark-queue", AnyView(PreviewWindow(model: queue, selection: [fixtures.bicep.id]))),
            ("14-dark-track-repair-as-mp3", AnyView(PreviewWindow(model: repairAsMP3, selection: [fixtures.bicep.id]))),
            ("13-dark-welcome", AnyView(PreviewWindow(model: empty, selection: []))),
        ])

        for (name, view) in shots {
            let dark = name.contains("-dark-")
            render(view, dark: dark, to: directory.appending(path: "\(name).png"))
        }
        for (name, view) in tall {
            render(view, dark: name.contains("-dark-"), size: CGSize(width: size.width, height: 1_040),
                   to: directory.appending(path: "\(name).png"))
        }
    }

    private static func render(_ view: AnyView, dark: Bool, size: CGSize = size, to url: URL) {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(DJColor.ring)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("renderPreviews: couldn't render \(url.lastPathComponent)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("renderPreviews: wrote \(url.path) (\(image.width)×\(image.height))")
    }
}

/// A stand-in for the main window, made of the app's own views.
private struct PreviewWindow: View {
    let model: AppModel
    let selection: Set<Track.ID>
    var sheet: AnyView?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: DJSize.sidebarIdeal)
            Rectangle().fill(DJColor.border).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                HStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if model.isShowingJobs {
                        Rectangle().fill(DJColor.border).frame(width: 1)
                        JobsPanel(scrolls: false)
                            .frame(width: DJSize.jobsPanelWidth)
                    }
                }
            }
            .background(DJColor.background)
        }
        .overlay {
            if let sheet {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                    sheet
                        .clipShape(RoundedRectangle(cornerRadius: DJRadius.xl))
                        .overlay(RoundedRectangle(cornerRadius: DJRadius.xl).strokeBorder(DJColor.border))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                        .padding(.top, 40)
                }
            }
        }
        .environment(model)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
            SidebarBrand()
                .padding(.horizontal, DJSpace.lg)
                .padding(.bottom, DJSpace.md)
            if model.tracks.isEmpty {
                Spacer()
                VStack(spacing: DJSpace.xs) {
                    Text("No tracks yet").djText(.headline).foregroundStyle(DJColor.foreground)
                    Text("Drop audio into the window.").djText(.caption).foregroundStyle(DJColor.mutedForeground)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                SidebarHeader(title: "Tracks", count: model.tracks.count)
                    .padding(.leading, 18)
                    .padding(.top, DJSpace.xs)
                    .padding(.bottom, 6)
                VStack(spacing: 2) {
                    ForEach(model.tracks) { track in
                        TrackRow(track: track, job: model.activeJob(for: track.id))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background {
                                if selection.contains(track.id) {
                                    RoundedRectangle(cornerRadius: DJRadius.md).fill(DJColor.sidebarAccent)
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
                if let job = model.runningHeavyJob {
                    SidebarActivityCard(job: job, waiting: model.activeHeavyJobs.count - 1)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(DJColor.sidebar)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Spacer()
            if model.engines.isFake {
                Text("Demo engines")
                    .font(.dj(11, weight: 600))
                    .foregroundStyle(DJColor.marker)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DJColor.markerSurface))
            }
            ForEach(["plus", model.activeJobCount > 0 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle", "gearshape"], id: \.self) { icon in
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(DJColor.mutedForeground)
            }
        }
        .padding(.horizontal, DJSpace.xl)
        .frame(height: 52)
    }

    @ViewBuilder private var detail: some View {
        let ids = model.tracks.map(\.id).filter(selection.contains)
        if ids.isEmpty {
            WelcomeContent(isTargeted: false, hasTracks: !model.tracks.isEmpty) {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -26)
        } else {
            TrackDetailContent(ids: ids)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A DJ's promo folder, mid-session.
@MainActor
struct PreviewFixtures {
    let floatingPoints: Track
    let overmono: Track
    let fred: Track
    let ross: Track
    let kettama: Track
    let bicep: Track
    let burial: Track
    let settings = AppSettings(defaults: UserDefaults(suiteName: "la.marko.djtools.previews")!)
    let mp3Settings = AppSettings(defaults: UserDefaults(suiteName: "la.marko.djtools.previews.mp3")!)

    var tracks: [Track] { [floatingPoints, overmono, fred, ross, kettama, bicep, burial] }

    init() {
        settings.stemsFormat = .aiff
        settings.repairFormat = .aiff
        mp3Settings.stemsFormat = .flac
        mp3Settings.repairFormat = .mp3_320
        let folder = URL.musicDirectory.appending(path: "Promos/October 2026", directoryHint: .isDirectory)
        let now = Date()
        func track(_ file: String, _ verdict: DJQualityVerdict?, bitrate: Int?, cutoff: Double?, duration: TimeInterval,
                   size: Int64, summary: String) -> Track {
            let url = folder.appending(path: file)
            var track = Track(url: url, addedAt: now)
            track.fileSize = size
            if let verdict {
                track.quality = DJQualityReport(
                    url: url, container: url.pathExtension.lowercased(),
                    isLosslessContainer: ["flac", "wav", "aiff"].contains(url.pathExtension.lowercased()),
                    declaredBitrateKbps: bitrate, sampleRate: 44_100, channels: 2, duration: duration,
                    cutoffHz: cutoff, verdict: verdict, summary: summary
                )
            }
            return track
        }
        var fp = track("Floating Points - Silhouettes (I, II & III).flac", .lossless, bitrate: 1012, cutoff: 21_950,
                       duration: 653, size: 82_400_000, summary: "Full range up to 22 kHz — genuinely lossless")
        let stemsFolder = URL.musicDirectory.appending(path: "DJ Tools/\(fp.name) (Stems)", directoryHint: .isDirectory)
        fp.results = [
            TrackResult(kind: .stems(model: .htdemucsFT, folder: stemsFolder,
                                     stems: Dictionary(uniqueKeysWithValues: DJStemModel.htdemucsFT.stemNames.map {
                                         ($0, stemsFolder.appending(path: "\($0).aiff"))
                                     })),
                        finishedAt: now.addingTimeInterval(-3_600)),
        ]
        // Quiet and dynamic: reaching −10 LUFS would clip, so the plan stops at the ceiling.
        fp.loudness = DJLoudnessReport(integratedLUFS: -15.3, truePeakDBTP: -3.0, samplePeakDBFS: -3.2,
                                       loudnessRangeLU: 9.4, duration: 653, sampleRate: 44_100, channels: 2)
        floatingPoints = fp
        overmono = track("Overmono - So U Kno.mp3", .lowQuality, bitrate: 128, cutoff: 16_000, duration: 312,
                         size: 5_010_000, summary: "Cuts off at 16 kHz — likely a 128 kbps MP3")
        fred = track("Fred again.. - Delilah (pull me out of this).wav", .fakeLossless, bitrate: 1411, cutoff: 16_100,
                     duration: 268, size: 47_300_000, summary: "Cuts off at 16 kHz — a lossy file saved as WAV")
        var rff = track("Ross From Friends - Talk To Me You'll Understand.m4a", .goodLossy, bitrate: 256, cutoff: 19_500,
                        duration: 401, size: 12_800_000, summary: "Cuts off at 19.5 kHz — a good 256 kbps encode")
        // A loud club master: comes down 3.8 dB.
        rff.loudness = DJLoudnessReport(integratedLUFS: -6.2, truePeakDBTP: 0.4, samplePeakDBFS: 0,
                                        loudnessRangeLU: 4.1, duration: 401, sampleRate: 44_100, channels: 2)
        ross = rff
        kettama = track("Kettama - It Gets Better.aiff", nil, bitrate: nil, cutoff: nil, duration: 0,
                        size: 61_000_000, summary: "")
        var glue = track("Bicep - Glue (Original Mix).mp3", .lowQuality, bitrate: 160, cutoff: 16_500, duration: 269,
                         size: 5_400_000, summary: "Cuts off at 16.5 kHz — likely a 160 kbps MP3")
        glue.loudness = DJLoudnessReport(integratedLUFS: -8.7, truePeakDBTP: -0.2, samplePeakDBFS: -0.4,
                                         loudnessRangeLU: 5.2, duration: 269, sampleRate: 44_100, channels: 2)
        let normalizedPlan = DJNormalizationPlan.pureGain(for: glue.loudness!, target: DJLoudnessTarget(lufs: -10, ceilingDBTP: -1))
        glue.results = [
            TrackResult(kind: .normalized(output: URL.musicDirectory.appending(path: "DJ Tools/\(glue.name) (Normalized).aiff"),
                                          plan: normalizedPlan),
                        finishedAt: now.addingTimeInterval(-600)),
        ]
        bicep = glue
        burial = track("Burial - Archangel (old rip).mp3", .lowQuality, bitrate: 64, cutoff: 11_000, duration: 238,
                       size: 1_900_000, summary: "MP3 64 kbps, cuts off at 11.0 kHz — low quality")
    }

    private func job(_ track: Track, _ kind: Job.Kind, _ state: Job.State, progress: Double? = nil, result: URL? = nil) -> Job {
        var job = Job(trackID: track.id, trackName: track.name, kind: kind, format: .aiff)
        job.state = state
        job.progress = progress
        job.resultURL = result
        return job
    }

    /// A check and a separation running.
    var liveJobs: [Job] {
        [job(kettama, .quality, .running),
         job(bicep, .stems(.htdemucs, .all), .running, progress: 0.42),
         job(fred, .repair, .queued)]
    }

    /// An Apollo repair running (with Apollo's own status line), stems waiting
    /// behind it: heavy jobs never overlap.
    var repairJobs: [Job] {
        var repair = job(burial, .repair, .running, progress: 0.31)
        repair.statusText = "Repairing"
        return [repair, job(bicep, .stems(.htdemucs, .all), .queued)]
    }

    /// A normalize running beside a separation, one waiting.
    var normalizeJobs: [Job] {
        let target = DJLoudnessTarget(lufs: -10, ceilingDBTP: -1)
        var normalizing = job(bicep, .normalize(target), .running, progress: 0.58)
        normalizing.statusText = "Saving AIFF"
        return [job(fred, .stems(.htdemucs, .all), .running, progress: 0.42),
                normalizing,
                job(ross, .normalize(target), .queued)]
    }

    /// Everything the queue panel can show.
    var queueJobs: [Job] {
        [job(floatingPoints, .stems(.htdemucsFT, .all), .finished, progress: 1,
             result: URL.musicDirectory.appending(path: "DJ Tools/\(floatingPoints.name) (Stems)")),
         job(ross, .repair, .failed("Repair stopped: the model ran out of memory. Close other apps and try again.")),
         job(kettama, .quality, .running),
         job(bicep, .stems(.htdemucs, .all), .running, progress: 0.42),
         job(fred, .repair, .queued),
         job(overmono, .stems(.htdemucs6s, .all), .queued)]
    }

    func model(tracks: [Track], jobs: [Job], apollo: DJApolloSetupState = .notInstalled, showsJobs: Bool = false,
               settings: AppSettings? = nil) -> AppModel {
        let support = FileManager.default.temporaryDirectory.appending(path: "DJToolsPreviews")
        let model = AppModel(engines: .fake(supportDirectory: support), settings: settings ?? self.settings, store: nil)
        model.installFixture(tracks: tracks, jobs: jobs, apolloState: apollo, showsJobs: showsJobs)
        return model
    }
}
#endif

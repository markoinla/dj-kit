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
/// sheets, popovers), so each screen is the app's own content views laid out
/// in a stand-in window: the sidebar's groups and rows in a plain stack, the
/// detail without its scroll view, the sheet over a dimmed window.
@MainActor
enum PreviewRenderer {
    static let size = CGSize(width: 1180, height: 760)

    static func run(into directory: URL) {
        FileCheck.assumeExists = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = PreviewFixtures()

        let empty = f.model(tracks: [], jobs: [])
        let session = f.model(tracks: f.tracks, jobs: f.sessionJobs, apollo: .ready)
        let multiRunning = f.model(tracks: f.tracks, jobs: f.multiJobs, apollo: .ready)
        let fresh = f.model(tracks: f.tracks, jobs: f.sessionJobs)
        let installing = f.model(tracks: f.tracks, jobs: f.sessionJobs, apollo: .installing("Downloading the repair model (66 MB)"))
        // Last run saved as MP3 320: the format menu and the MP3 warning beside it.
        let asMP3 = f.model(tracks: f.tracks, jobs: f.sessionJobs, apollo: .ready, settings: f.mp3Settings)

        func window(_ model: AppModel, _ selection: [Track], sheet: AnyView? = nil) -> AnyView {
            AnyView(PreviewWindow(model: model, selection: Set(selection.map(\.id)), sheet: sheet))
        }
        let shots: [(String, AnyView)] = [
            ("01-welcome", window(empty, [])),
            ("02-setup-lossy", window(session, [f.overmono])),
            ("03-setup-lossless-match", window(session, [f.kettama])),
            ("04-setup-analyzing", window(session, [f.sammy])),
            ("05-setup-multi", window(session, [f.overmono, f.ross, f.kettama])),
            ("06-processing", window(session, [f.bicep])),
            ("07-processing-queued", window(session, [f.fred])),
            ("08-processing-multi", window(multiRunning, [f.bicep, f.fred, f.floatingPoints])),
            ("09-done", window(session, [f.floatingPoints])),
            ("10-failed", window(session, [f.burial])),
            ("11-setup-repair-as-mp3", window(asMP3, [f.overmono])),
            ("12-apollo-setup", window(fresh, [f.overmono], sheet: AnyView(ApolloSetupContent(state: .notInstalled, trackCount: 1)))),
            ("13-apollo-installing", window(installing, [f.overmono],
                                            sheet: AnyView(ApolloSetupContent(state: installing.apolloState, trackCount: 1)))),
            ("14-dark-setup-lossy", window(session, [f.overmono])),
            ("15-dark-processing", window(session, [f.bicep])),
            ("16-dark-done", window(session, [f.floatingPoints])),
            ("17-dark-setup-multi", window(session, [f.overmono, f.ross, f.kettama])),
            ("18-dark-welcome", window(empty, [])),
        ]
        for (name, view) in shots {
            render(view, dark: name.contains("-dark-"), to: directory.appending(path: "\(name).png"))
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
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    Text("Drop audio here").djText(.caption).foregroundStyle(DJColor.mutedForeground)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // The List's groups, as `TrackSidebar` builds them.
                ForEach(model.trackGroups, id: \.stage) { group in
                    SidebarHeader(title: group.stage.title, count: group.tracks.count)
                        .padding(.leading, 18)
                        .padding(.top, DJSpace.sm)
                        .padding(.bottom, 4)
                    VStack(spacing: 2) {
                        ForEach(group.tracks) { track in
                            SidebarTrackRow(track: track, stage: group.stage)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(.bottom, DJSpace.xs)
                }
                Spacer()
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
            ForEach(["plus", "gearshape"], id: \.self) { icon in
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
    let sammy: Track
    let settings = AppSettings(defaults: UserDefaults(suiteName: "la.marko.djtools.previews")!)
    let mp3Settings = AppSettings(defaults: UserDefaults(suiteName: "la.marko.djtools.previews.mp3")!)

    var tracks: [Track] { [floatingPoints, overmono, fred, ross, kettama, bicep, burial, sammy] }

    private static let target = DJLoudnessTarget(lufs: -10, ceilingDBTP: -1)

    init() {
        var recipe = ProcessRecipe()
        recipe.stems = true
        settings.lastRecipe = recipe
        var mp3 = ProcessRecipe()
        mp3.format = .mp3_320
        mp3Settings.lastRecipe = mp3
        let folder = URL.musicDirectory.appending(path: "Promos/October 2026", directoryHint: .isDirectory)
        let output = URL.musicDirectory.appending(path: "DJ Tools", directoryHint: .isDirectory)
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
        func loudness(_ lufs: Double, peak: Double, duration: TimeInterval) -> DJLoudnessReport {
            DJLoudnessReport(integratedLUFS: lufs, truePeakDBTP: peak, samplePeakDBFS: peak - 0.2,
                             loudnessRangeLU: 6, duration: duration, sampleRate: 44_100, channels: 2)
        }

        // Done: normalized and split into four stems an hour ago.
        var fp = track("Floating Points - Silhouettes (I, II & III).flac", .lossless, bitrate: 1012, cutoff: 21_950,
                       duration: 653, size: 82_400_000, summary: "Full range up to 22 kHz — genuinely lossless")
        fp.loudness = loudness(-15.3, peak: -3.0, duration: 653)
        fp.identifiedAt = now
        let stemsFolder = output.appending(path: "\(fp.name) (Stems)", directoryHint: .isDirectory)
        fp.results = [
            TrackResult(kind: .processed(ProcessedFiles(
                            output: output.appending(path: "\(fp.name).aiff"),
                            repaired: false,
                            normalization: DJNormalizationPlan.pureGain(for: fp.loudness!, target: Self.target),
                            stemModel: .htdemucs, stemsFolder: stemsFolder,
                            stems: Dictionary(uniqueKeysWithValues: DJStemModel.htdemucs.stemNames.map {
                                ($0, stemsFolder.appending(path: "\(fp.name) (\($0.capitalized)).aiff"))
                            }))),
                        finishedAt: now.addingTimeInterval(-3_600)),
        ]
        floatingPoints = fp

        // Setup, lossy: Repair suggested, loudness measured, Track ID not run.
        var so = track("Overmono - So U Kno.mp3", .lowQuality, bitrate: 128, cutoff: 16_000, duration: 312,
                       size: 5_010_000, summary: "Cuts off at 16 kHz — likely a 128 kbps MP3")
        so.loudness = loudness(-7.9, peak: 0.2, duration: 312)
        overmono = so

        // Waiting in line behind Bicep.
        var delilah = track("Fred again.. - Delilah (pull me out of this).wav", .fakeLossless, bitrate: 1411, cutoff: 16_100,
                            duration: 268, size: 47_300_000, summary: "Cuts off at 16 kHz — a lossy file saved as WAV")
        delilah.identifiedAt = now
        fred = delilah

        // A loud club master: comes down 3.8 dB.
        var rff = track("Ross From Friends - Talk To Me You'll Understand.m4a", .goodLossy, bitrate: 256, cutoff: 19_500,
                        duration: 401, size: 12_800_000, summary: "Cuts off at 19.5 kHz — a good 256 kbps encode")
        rff.loudness = loudness(-6.2, peak: 0.4, duration: 401)
        rff.identifiedAt = now
        ross = rff

        // Lossless, with a Track ID match waiting for Apply.
        var ktm = track("KTMA_IGB_master_v3.aiff", .lossless, bitrate: nil, cutoff: 21_900, duration: 384,
                        size: 67_800_000, summary: "Full range up to 22 kHz — genuinely lossless")
        ktm.loudness = loudness(-8.4, peak: -0.6, duration: 384)
        ktm.identity = DJTrackIdentity(title: "It Gets Better", artist: "Kettama", album: "It Gets Better",
                                       label: "Steel City Dance Discs", genre: "House", releaseDate: "2026-09-12",
                                       durationSeconds: 386, hits: 3, listens: 3)
        ktm.identifiedAt = now
        kettama = ktm

        // Repairing now, stems after.
        var glue = track("Bicep - Glue (Original Mix).mp3", .lowQuality, bitrate: 160, cutoff: 16_500, duration: 269,
                         size: 5_400_000, summary: "Cuts off at 16.5 kHz — likely a 160 kbps MP3")
        glue.identifiedAt = now
        bicep = glue

        // The last run failed.
        var archangel = track("Burial - Archangel (old rip).mp3", .lowQuality, bitrate: 64, cutoff: 11_000, duration: 238,
                              size: 1_900_000, summary: "MP3 64 kbps, cuts off at 11.0 kHz — low quality")
        archangel.identifiedAt = now
        burial = archangel

        // Just dropped: checked, Track ID listening.
        sammy = track("Sammy Virji - I Guess We're Not The Same.mp3", .goodLossy, bitrate: 320, cutoff: 20_000,
                      duration: 221, size: 8_800_000, summary: "Cuts off at 20 kHz — a good 320 kbps encode")
    }

    private func job(_ track: Track, _ kind: Job.Kind, _ state: Job.State, progress: Double? = nil) -> Job {
        var job = Job(trackID: track.id, trackName: track.name, kind: kind, format: .aiff)
        job.state = state
        job.progress = progress
        return job
    }

    private func process(repair: Bool, normalize: Bool = true, stems: Bool = false) -> Job.Kind {
        var recipe = ProcessRecipe()
        recipe.repair = repair ? .on : .off
        recipe.normalize = normalize
        recipe.stems = stems
        return .process(recipe, Self.target)
    }

    /// Bicep repairing (stems next), Fred waiting, Burial's run failed,
    /// Sammy's Track ID listening.
    var sessionJobs: [Job] {
        var running = job(bicep, process(repair: true, stems: true), .running, progress: 0.18)
        running.steps = [.repair, .normalize, .stems]
        running.currentStep = .repair
        running.stepProgress = 0.42
        running.statusText = "Repairing"
        return [
            running,
            job(fred, process(repair: true), .queued),
            job(burial, process(repair: true), .failed("Repair stopped: out of memory.")),
            job(sammy, .identify, .running, progress: 0.4),
        ]
    }

    /// Three selected: one running, one waiting, one finished.
    var multiJobs: [Job] {
        var finished = job(floatingPoints, process(repair: false, stems: true), .finished, progress: 1)
        finished.steps = [.normalize, .stems]
        return sessionJobs + [finished]
    }

    func model(tracks: [Track], jobs: [Job], apollo: DJApolloSetupState = .notInstalled,
               settings: AppSettings? = nil) -> AppModel {
        let support = FileManager.default.temporaryDirectory.appending(path: "DJToolsPreviews")
        let model = AppModel(engines: .fake(supportDirectory: support), settings: settings ?? self.settings, store: nil)
        model.installFixture(tracks: tracks, jobs: jobs, apolloState: apollo)
        return model
    }
}
#endif

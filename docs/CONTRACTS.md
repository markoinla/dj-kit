# Module contracts

The app is a native SwiftUI macOS app plus six local Swift packages it links
(QualityKit, StemsKit, ApolloMLX, AudioExport, LoudnessKit, AnalysisKit). The Python Apollo project and its Swift
bridge stay in the repo as the reference implementation but are no longer linked. Each piece is built by a separate worker; these are the seams between them.
Change a contract only by editing this file and saying so.

Common: macOS 14.4 minimum (matches Wax Studio), Swift 6 language mode, Apple Silicon
(arm64) only. Bundle ID `la.marko.djtools`, display name "DJ Tools" (placeholder).
App data lives in `~/Library/Application Support/DJTools/`. Default output folder
`~/Music/DJ Tools/`. No code signing yet (ad-hoc `-` / `CODE_SIGNING_ALLOWED=NO`).

## Packages/QualityKit — bad-file detector (pure Swift: AVFoundation + Accelerate)

```swift
public enum QualityVerdict: String, Sendable, Codable { case lossless, goodLossy, lowQuality, fakeLossless, unknown }
public struct QualityReport: Sendable, Codable, Equatable {
  public var url: URL
  public var container: String          // "mp3", "flac", "wav", "aiff", "m4a", ...
  public var isLosslessContainer: Bool
  public var declaredBitrateKbps: Int?  // from the file, when it has one
  public var sampleRate: Double
  public var channels: Int
  public var duration: TimeInterval
  public var cutoffHz: Double?          // estimated spectral cutoff (where the highs stop)
  public var verdict: QualityVerdict
  public var summary: String            // one line for the UI, e.g. "Cuts off at 16 kHz — likely a 128 kbps MP3"
}
public enum QualityAnalyzer {
  public static func analyze(_ url: URL) async throws -> QualityReport
}
```

## Packages/StemsKit — stem separation (wraps ssmall256/demucs-mlx-swift)

```swift
public enum StemModel: String, Sendable, CaseIterable { case htdemucs, htdemucsFT, htdemucs6s }
public struct StemResult: Sendable { public var stems: [String: URL] }   // "vocals","drums","bass","other"(,"guitar","piano")
public actor StemSeparator {
  public init(model: StemModel = .htdemucs)
  public func separate(input: URL, outputDirectory: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> StemResult
}
```
Writes `<outputDirectory>/<track name> (Stems)/<stem>.wav`. Model weights download on first
use into App Support (`DJTools/models/`), never into the bundle. (The app runs it into a
scratch folder and saves the result through AudioExport; see below.)

## apollo/ + Packages/ApolloBridge — Apollo repair, Python behind a Swift bridge (reference only)

No longer linked or bundled by the app (replaced by ApolloMLX below). Kept untouched as the
reference implementation the MLX port is checked against.

`apollo/` is a uv project (Python) wrapping https://github.com/JusperLee/Apollo inference,
weights from Hugging Face `JusperLee/Apollo`. Entry point:

```
uv run --project <apollo dir> apollo-repair --input IN --output OUT.wav [--device auto|mps|cpu]
```
stdout is JSON lines, one object per line, nothing else on stdout (logs go to stderr):
`{"event":"status","message":"Loading model"}`, `{"event":"progress","fraction":0.42}`,
`{"event":"done","output":"/path/OUT.wav"}`, `{"event":"error","message":"..."}`. Exit 0 on success.

`ApolloBridge` (pure Swift, no Python linkage):

```swift
public enum ApolloSetupState: Sendable, Equatable { case notInstalled, installing(String), ready, failed(String) }
public actor ApolloRuntime {
  public init(projectDirectory: URL, supportDirectory: URL)   // supportDirectory = App Support/DJTools
  public func state() async -> ApolloSetupState
  public func install(progress: @escaping @Sendable (String) -> Void) async throws   // uv + python + deps + weights
  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL
  public func cancel() async
}
```
(Additive: `repair(input:output:progress:status:)` also passes Apollo's status lines —
"Loading model", "Repairing on MPS" — which the app shows on the running step.)

`install` downloads `uv` into `supportDirectory/runtime/bin` with the official standalone
installer (no Homebrew, no sudo) and keeps uv's cache, Python and venv under
`supportDirectory/runtime/`.

## app/ — the SwiftUI shell (XcodeGen, `app/project.yml`)

Depends on QualityKit, StemsKit, ApolloMLX, AudioExport, LoudnessKit and AnalysisKit by local path. Drop files or folders in;
they're added and selected. The detail pane is a stepper, ① Analyze → ② Repair → ③ Normalize → ④ Stems, in
one of three states derived from the track's jobs and results: **setup** (Analyze — the quality check and Track
ID, run on drop — shows its own progress, then ②–④ as switches with options, the file type and Process),
**processing** (one run per track that does them all, `Job.Kind.process`; each step waiting, running with its
own bar from `Job.currentStep`/`stepProgress`, done or skipped; Cancel), and **done** (what the run did, the
saved files as draggable rows/stem chips for Rekordbox, Process Again). The steps and file type start from the
last run (`AppSettings.lastRecipe`; Stems off the first time); Repair starts from the quality check's
suggestion (on for low quality / fake lossless). The sidebar groups tracks as Processing / Ready / Done; there
is no separate queue.

**Track ID** (`Engines/TrackIdentifier.swift`, behind `TrackIdentifying`): ShazamKit listens to three
12 s windows (30/50/70 % in), the windows vote, MusicKit's catalog fills in album, label, release
date, ISRC and 1400 px artwork, preferring the release closest in length to the file. Runs on drop
(Settings ▸ Track ID), two at a time. The match waits on the track (`Track.identity`) until Apply:
`AudioRetagger` merges the tags into the file without re-encoding (BPM, key and the like stay) and,
by default, renames it `Artist - Title.<ext>` in place. Needs the ShazamKit and MusicKit App
Services on `la.marko.djtools` and the team-signed build. Design follows Wax Studio
(`Wax Studio`, see its `WaxMac/DesignSystem`).

## Packages/ApolloMLX — native port of Apollo (MLX Swift), the app's repair engine

Same job as the Python bridge, no Python. Verified on build-mac (M5 Air, 16 GB): fp32 parity
62.8 dB SNR vs PyTorch on music (119 dB on white noise); fp16 4:00 track in 82 s / 2.7 GiB
peak vs Python MPS 131 s / 4.4 GiB. Wired into the app behind `ApolloRepairing`
(`ApolloMLXAdapter`, fp16) since 2026-10-06; the app sets `MLX_ENABLE_TF32=0` at launch.

```swift
public actor ApolloMLXRepairer {
  public init(modelsDirectory: URL)            // app: App Support/DJTools/models/apollo-mlx
  public var isPrepared: Bool { get }          // converted weights exist
  public func prepare(progress: @escaping @Sendable (String) -> Void) async throws
      // download pinned HF checkpoint (66 MB), SHA-256 check, convert in Swift → apollo-mlx.safetensors
  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL
      // 44.1 kHz 24-bit WAV; cancel by cancelling the calling Task (checked between chunks)
  public func removeWeights() throws
}
```

## Packages/AudioExport — save results as AIFF, WAV, FLAC or MP3

Converts a finished PCM WAV (the engines' output) to the user's chosen file type, with tags.
Pure Swift + AudioToolbox, plus vendored LAME 3.100 (LGPL, encoder only) for MP3.

```swift
public enum AudioFileFormat: String, CaseIterable, Codable, Sendable {   // raw values are stored
  case aiff, wav, flac, mp3_320 = "mp3-320", mp3_256 = "mp3-256", mp3_192 = "mp3-192"
  public var fileExtension: String; public var isLossless: Bool; public var writesTags: Bool
  public var title: String; public var shortTitle: String
}
public struct AudioTags: Sendable, Equatable {   // title, artist, album, artwork, genre, year, label, isrc, comment, bpm, key
  public static func read(from url: URL) async -> AudioTags
  public func suffixingTitle(_ suffix: String, fallbackTitle: String) -> AudioTags
}
public enum AudioExporter {
  public static func export(_ source: URL, to destination: URL, format: AudioFileFormat,
                            tags: AudioTags? = nil, gainDB: Double = 0, removingSource: Bool = false,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL
}
```
Lossless keeps the source's rate and is bit-exact (24-bit, 16-bit for 16-bit sources). MP3 is
CBR joint stereo `-q 0`, resampled to 44.1 kHz, with a LAME/Info tag (exact length). Tags go
into AIFF (ID3 chunk), FLAC (Vorbis comments + picture) and MP3 (ID3v2.3); WAV gets none.
Atomic write; cancelling the task leaves nothing behind. `gainDB` scales every sample on the way
through (normalization); with a gain, lossless output is always 24-bit. No clipping protection:
the caller keeps peaks below full scale. The source may be any file AVAudioFile decodes.

The app (`ResultWriter.process`) runs a Process run in a scratch folder and saves once:
`<out>/<name>.<ext>` (the finished track, when it repaired or normalized; replaced on a re-run) and
`<out>/<name> (Stems)/<name> (Vocals).<ext>`, where `<name>` is "Artist - Title" when the tags (or a
Track ID match) have both, else the file name. No suffix on the finished track's name or title: what
was done goes in the comment tag ("Repaired · −10.0 LUFS"), after the file's own comment. Results are
tagged with the file's tags plus the match. A separation keeps the stems the run picks
(`DJStemChoice`); "instrumental" is every stem but the vocals summed. AIFF is the default (Rekordbox
reads its tags and artwork).

## Packages/LoudnessKit — loudness measurement and normalization (pure Swift: AVFoundation + Accelerate)

ITU-R BS.1770-4 / EBU R128. K-weighting derived for the file's own sample rate (matches the
published 48 kHz coefficients), 400 ms blocks with 75% overlap, absolute −70 LUFS gate and
relative −10 LU gate; EBU Tech 3342 LRA (3 s short-term every 100 ms, −20 LU relative gate,
95th − 10th percentile); true peak by polyphase windowed-sinc interpolation, 8× up to 48 kHz,
4× up to 96 kHz, 2× above. Silence is `-infinity`.

```swift
public struct LoudnessReport: Sendable, Codable, Equatable {
  public var integratedLUFS: Double, truePeakDBTP: Double, samplePeakDBFS: Double
  public var loudnessRangeLU: Double?          // nil under 3 s or all gated out
  public var duration: TimeInterval, sampleRate: Double, channels: Int
  public var isSilent: Bool { get }
}
public enum LoudnessAnalyzer {   // full decode; ~0.4 s for a 3½-minute FLAC on an M5 Air
  public static func measure(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessReport
}
public struct NormalizationPlan: Sendable, Codable, Equatable {
  public var targetLUFS, ceilingDBTP, gainDB: Double
  public var limitedByCeiling: Bool             // the gain stopped where the true peak meets the ceiling
  public var resultingLUFS, resultingTruePeakDBTP: Double
}
public enum Normalizer {
  public static func gain(for: LoudnessReport, targetLUFS: Double, ceilingDBTP: Double) -> NormalizationPlan
}
public final class LoudnessMeter   // streaming core: process(planar floats) … finish()
```
Pure gain, never a limiter or compression: when the target would push the true peak past the
ceiling, the gain is capped there (which is a cut when the source already peaks above it).
`loudness <file>… [--target] [--ceiling]` prints the report and plan as JSON.

The app's flow (`ResultWriter.process`): measure Apollo's scratch WAV (or the source when not
repairing), plan, then `AudioExporter.export` it with `gainDB`. The stems are separated from the same
audio and saved with the same gain, so they still sum back to the finished track. Measuring is never
part of the automatic quality check (it needs a full decode); the Normalize row measures lazily.

## Packages/AnalysisKit — BPM and musical key (optional; tags only where missing)

Key: vendored libkeyfinder (GPL-3, Mixxx's key detector) as the `CKeyFinder` C++ target behind a
C shim, its FFTW calls replaced by vDSP (no brew deps). Tempo: Beat This! (CPJKU, MIT) final0 ported
to MLX (fp16; ~0.7 s per 6 minutes on an M4 Pro on mains), beats from upstream's "minimal"
postprocessing (no madmom DBN). BPM is the least-squares slope of beat time against beat index over
every run of beats on one consistent grid (pooled, one intercept per run), not 60 / median interval
(Beat This!'s 50 fps grid quantizes single intervals to 20 ms). Weights: `model.safetensors` from
Hugging Face `safe-models/beat-this-final0` at revision `39ec648…` (81 MB, SHA-256 pinned in
`BeatTracker`), downloaded on first use into `App Support/DJTools/models/beat-this/`, never bundled.
MLX means building and testing with xcodebuild (Metal shaders). Budget: ≤ 3 s for a 6-minute track
on an M-series Mac on mains power, decode included. Beatgrid stays Rekordbox's.

```swift
public struct MusicalKey: Sendable, Codable, Hashable {
  public var tonic: Int          // pitch class, 0 = C … 11 = B
  public var isMinor: Bool
  public var camelotNumber: Int { get }  // 1…12
  public var camelot: String { get }   // "8A" (minor = A, major = B)
  public var musical: String { get }   // Rekordbox spelling: Abm Ebm Bbm Fm Cm Gm Dm Am Em Bm F#m Dbm /
                                       // B F# Db Ab Eb Bb F C G D A E
  public init?(parsing tag: String)    // "Am", "A minor", "Amin", "8A", "08A", "G#m", "1m"/"1d" (Open Key), …
                                       // a trailing capital "M" is major ("C#M"), "m" minor
}
public struct KeyEstimate: Sendable, Codable, Equatable {
  public var key: MusicalKey
  public var margin: Double      // (best − second) / (best − worst) of libkeyfinder's 24 scores, 0…1; debug only
}
public struct TempoEstimate: Sendable, Codable, Equatable {
  public static let steadyThreshold = 0.03   // electronic 0.002–0.0065, disco 0.0085, live funk 0.024
  public var rawBPM: Double      // from the beats, before folding
  public var beatCount: Int
  public var stability: Double   // coefficient of variation of the beat interval over 4-beat spans on the grid
  public var isSteady: Bool { get }    // stability < steadyThreshold
  public func bpm(in range: ClosedRange<Double>) -> Double
      // halve/double into range when outside it; one that would overshoot the other end stays (175.4 → 175.4)
}
public enum BPMRange {
  public static let standard: ClosedRange<Double>   // 88...175
  public static let slow: ClosedRange<Double>       // 60...120
  public static func forGenre(_ genre: String?) -> ClosedRange<Double>
      // standard when it names a club style (house, techno, …step, garage, bass, trance, break(s),
      // dnb, jungle, electro — "Electronic(a)" isn't one); else slow for downtempo, trip-hop,
      // chill(out), lounge, reggae, dub, ambient; else standard
  public static func forGenres(_ genres: [String?]) -> ClosedRange<Double>
      // standard if any names a club style, else slow if any is slow, else standard
}
public enum BPMFormat {
  public static func string(_ bpm: Double) -> String   // "124" within ±0.05 of a whole number, else "123.5"
}
public struct MusicalAnalysis: Sendable, Codable, Equatable {
  public var tempo: TempoEstimate?      // nil: no beats found
  public var key: KeyEstimate?          // nil: silent / atonal
  public var duration: TimeInterval
}
public enum KeyDetector {   // libkeyfinder; pure CPU, thread-safe
  public static func detect(monoSamples: [Float], sampleRate: Double) -> KeyEstimate?
}
public actor BeatTracker {
  public init(modelsDirectory: URL)              // app: App Support/DJTools/models/beat-this
  public var isPrepared: Bool { get }
  public func prepare(progress: @escaping @Sendable (String) -> Void) async throws   // download + verify
  public func tempo(monoSamples: [Float], sampleRate: Double) async throws -> TempoEstimate?  // resamples itself
  public func removeWeights() throws
}
public enum MusicalAnalyzerError: Error, LocalizedError {
  case unreadable(String)         // the file
  case modelUnavailable(String)   // download / check failed (offline, server): transient
}
public actor MusicalAnalyzer {
  public init(modelsDirectory: URL)
  public var isPrepared: Bool { get async }
  public nonisolated func analyze(_ url: URL, retryingModel: Bool = false,
                                  progress: (@Sendable (Double) -> Void)? = nil,
                                  status: (@Sendable (String) -> Void)? = nil) async throws -> MusicalAnalysis
      // one streaming AVAudioFile decode to 22050 Hz mono (no full-rate copy; the tracker skips its
      // resample, libkeyfinder gives the same keys); key (CPU) and tempo (GPU) concurrently from it;
      // prepares the model on first use, and again if the weights went missing (one shared download
      // for concurrent calls; a cancelled caller returns at once, the last one cancels it). After a
      // failed setup, calls throw .modelUnavailable at once for 2 minutes unless retryingModel (Try
      // Again). The download gives up after 15 s without data.
      // status: "Downloading model…" / "Verifying model…" while preparing, then "Analyzing…".
  public func removeWeights() async throws
}
```
`analysis-eval <rekordbox.xml | folder> [--models DIR] [--limit N] [--csv out.csv]` compares against
Rekordbox's `AverageBpm`/`Tonality` (XML collection export) or the files' own BPM/key tags (folder),
detected BPM folded with `BPMRange.forGenre(genre)`; reports BPM agreement (±0.5, half/double
separately), key agreement (exact, relative, fifth, parallel), unsteady count, mean time per track,
and per-track mismatches. Read-only.

The app (`MusicalAnalyzing` / `AnalysisKitAdapter`, mirrors `DJMusicalAnalysis` …): Settings ▸
Analysis ("Detect BPM and key", on — gates all of the below; "Key tag" Musical/Camelot, Musical; "Remove Model…").
Runs on add (and lazily when an unanalyzed track is shown) as `Job.Kind.analyze`, 2 at a time; the
result is `Track.analysis` (raw), with the file's own BPM/key/genre tags at that time in
`Track.fileTags`; never re-run once there. A file error is kept (`Track.analysisError`, Try Again);
a model that couldn't be set up only fails that job (and drops the queued ones), retried on the
next trigger (showing the track, Process, Apply, Try Again, relaunch), never by itself; within two
minutes of a failure only Try Again actually retries, the rest fail fast. Readout in the Analyze row: `124 BPM · 8A · Am`, `~96 BPM`
when the tempo isn't steady, a dim `tag: 123 · 9A · Em` when the file's own tags disagree (±0.5 BPM
against the folded detection / a different key). BPM is folded with `BPMRange.forGenres` at display/save
time over the file's own genre tag (as first read, kept through Apply) and Track ID's genre (unless
turned down): standard when either names a club style ("Lounge" + "House"), else slow when either
is slow, so a "Downtempo" file stays slow under a catalog's "Electronic";
the readout, Process outputs and Apply use the same rule. Writing: Process outputs (finished track + stems)
and the original on Apply get `AudioTags.bpm` / `AudioTags.key` only where the file has none (any
BPM text but "0" counts); unsteady tempo is never written; nothing is written with the setting off. A Process run first waits, in one loop,
until the track has no quality check, Track ID or analysis active (a queued analysis starts ahead of
the queue) and isn't being applied, then re-reads its path; Apply starts one if needed and waits for it. A failed
analysis saves without and shows its error.

AudioExport additions: `AudioTags.bpm: String?`, `AudioTags.key: String?` — ID3 TBPM/TKEY (AIFF,
MP3), Vorbis BPM/INITIALKEY (FLAC); read, written by `AudioExporter.export` and merged by
`AudioRetagger` like the other fields.

# Module contracts

The app is a native SwiftUI macOS app plus five local Swift packages it links
(QualityKit, StemsKit, ApolloMLX, AudioExport, LoudnessKit). The Python Apollo project and its Swift
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
"Loading model", "Repairing on MPS" — which the app shows in the job row.)

`install` downloads `uv` into `supportDirectory/runtime/bin` with the official standalone
installer (no Homebrew, no sudo) and keeps uv's cache, Python and venv under
`supportDirectory/runtime/`.

## app/ — the SwiftUI shell (XcodeGen, `app/project.yml`)

Depends on QualityKit, StemsKit, ApolloMLX, AudioExport and LoudnessKit by local path. Drop files or folders in;
each track gets Track ID and a quality check straight away, and a Process sheet opens: Repair → Normalize →
Stems as switches, one run per track that does them all (`Job.Kind.process`). The steps and file type start
from the last run (`AppSettings.lastRecipe`; Stems off the first time); Repair starts from the quality
check's suggestion (on for low quality / fake lossless). A job queue shows progress; results land in the
output folder with Reveal in Finder.

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
public struct AudioTags: Sendable, Equatable {        // title, artist, album, artwork
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

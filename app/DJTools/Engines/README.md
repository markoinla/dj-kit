# Engines: the seam to the packages

The app talks to the packages only through five protocols in
`EngineProtocols.swift`, using its own copies of the contract types in
`EngineTypes.swift` (`DJQualityReport`, `DJStemModel`, `DJMusicalAnalysis`, …
— same fields and cases as `docs/CONTRACTS.md`, prefixed `DJ` so nothing
clashes). Only `RealEngines.swift` imports QualityKit, StemsKit, ApolloMLX,
LoudnessKit and AnalysisKit; it also gives the mirror types AnalysisKit's pure
helpers (`DJMusicalKey.camelot` / `.musical` / `init?(parsing:)`,
`DJTempoEstimate.isSteady` / `bpm(genre:)`, `DJBPM.string`), which the fakes
and views use too.

| Protocol | Adapter (`RealEngines.swift`) | Package API |
| --- | --- | --- |
| `QualityChecking` | `QualityKitAdapter` | `QualityAnalyzer.analyze(_:)` |
| `StemSeparating` | `StemsKitAdapter` (actor, one `StemSeparator` per model, kept alive) | `StemSeparator(model:modelsDirectory:).separate(...)` |
| `ApolloRepairing` | `ApolloMLXAdapter` (actor) | `ApolloMLXRepairer(modelsDirectory:)` |
| `ApolloRepairing.reset()` | `removeWeights()` | — |
| `LoudnessMeasuring` | `LoudnessKitAdapter` | `LoudnessAnalyzer.measure(_:progress:)`, `Normalizer.gain(for:targetLUFS:ceilingDBTP:)` |
| `MusicalAnalyzing` | `AnalysisKitAdapter` | `MusicalAnalyzer(modelsDirectory:).analyze(_:progress:status:)`, `removeWeights()` |

Adapters deliver every progress/status callback on the main queue, in order
(`MainHop`).

Apollo is the native MLX port (`Packages/ApolloMLX`), no Python. The adapter
maps state ↔ `isPrepared`, install ↔ `prepare()` (downloads the pinned
Hugging Face checkpoint, SHA-checks it, converts it in Swift to
`apollo-mlx.safetensors`, ~66 MB), repair at fp16, cancel ↔ cancelling the
repair's `Task` (checked between chunks), reset ↔ `removeWeights()`. Weights
live in `<supportDirectory>/models/apollo-mlx/`. The package only reports
progress, so the adapter makes the status lines: "Loading model" until the
first chunk, "Repairing", "Writing output" at 100 %. `DJToolsMain` sets
`MLX_ENABLE_TF32=0` before anything touches MLX (the parity numbers in
ApolloMLX were measured that way). StemsKit and ApolloMLX share one
mlx-swift (both pin `upToNextMinor(from: "0.32.3")`).

BPM and key: `MusicalAnalyzer` decodes once and runs libkeyfinder and Beat
This! side by side; the tempo model (81 MB) downloads on the first analysis
into `<supportDirectory>/models/beat-this/` with "Downloading model…" as the
job's status line. When it can't be set up (offline) only that job fails
(`DJAnalysisModelUnavailable`, not kept on the track); the next trigger tries
again. AnalysisKit pins the same mlx-swift as the other two.

`apollo/` (Python) and `Packages/ApolloBridge` stay in the repo as the
reference implementation; the app no longer links or bundles them.

## Saving results (`Model/ResultWriter.swift`)

One Process run (`ResultWriter.process`) does repair → normalize → stems on
one track. Apollo writes its 24-bit WAV into a scratch folder on the output
folder's volume; LoudnessKit measures that (or the source, without repair);
`AudioExport` saves it once with the plan's gain as the run's format (AIFF
default, WAV, FLAC, MP3 320/256/192); Demucs separates the same audio and
each stem is saved with the same gain. Tags: the source's plus the Track ID
match, title unsuffixed on the finished track (" (Vocals)" … on stems), and
"Repaired · −10.0 LUFS" appended to the comment, plus the detected BPM and
key where the source has none (`TrackTags.fillingAnalysis`: BPM folded for the
genre the file is written with, only for a steady tempo; key spelled per Settings ▸ Analysis; existing
tags always win). Apply writes them into the original under the same rule. Names:
`<out>/<track>.<ext>` (replaced on a re-run, never over the source) and
`<out>/<track> (Stems)/<track> (Vocals).<ext>` (replacing an older folder).
The scratch folder is deleted however the run ends. The last run's steps and
format are remembered (`AppSettings.lastRecipe`).

Besides the run's overall `progress`, `process` reports the running step and its
own fraction (`step: (ProcessStep, Double)`, through the main queue, never
backwards); saving the finished track counts as Normalize (Repair when it
doesn't normalize), mixing and saving stems as Stems (~30 % of that step for
lossless, more for MP3). `AppModel` keeps them on the `Job` (`steps`,
`currentStep`, `stepProgress`) for the stepper; the sidebar row shows the
overall bar.

## The window

No sheets or queue panel: dropping (or ⌘O) adds and selects tracks, and the
detail pane is a stepper — ① Analyze (quality check, Track ID and BPM / key,
automatic on drop; "124 BPM · 8A · Am", with a dim "tag: …" line when the
file's own tags disagree) → ② Repair → ③ Normalize → ④ Stems — in setup,
processing or done state, all derived from the track's jobs and results
(`AppModel.stage(of:)`, `TrackStage`). The sidebar groups tracks the same
way (Processing / Ready / Done). Finished files are draggable straight into
Rekordbox.

`Engines.real(supportDirectory:)` builds them; `supportDirectory` is
`AppPaths.support` (`~/Library/Application Support/DJTools`, or
`-supportDirectory <path>`).

Process runs that repair or separate (stems ~5.4 GB peak footprint, Apollo
~2.9 GB, one after the other inside the run) share one slot in `AppModel`
(`heavyInFlight`), so they never overlap. A run first waits for its track's
quality check and Track ID (the name and the repair suggestion come from
them), and for its BPM / key detection (`Job.Kind.analyze`, two at a time
with their own cap; a queued one for this track starts straight away).
Loudness measuring (`Job.Kind.loudness`, lazily for the Normalize row)
and normalize-only runs are light but decode the whole file: two at a time
(`maxConcurrentDecodes`), beside the heavy slot. Quality checks never measure
loudness.

## Building

```sh
cd app && xcodegen
xcodebuild -project DJTools.xcodeproj -scheme DJTools -configuration Release \
  -destination platform=macOS,arch=arm64 -derivedDataPath .dd \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` on the command line matters for Release:
without it the package targets build universal, and demucs-mlx-swift doesn't
compile for x86_64 (no `Float16`). The app bundle then holds
`Resources/mlx-swift_Cmlx.bundle` (default.metallib) and no `Resources/apollo/`.
Run `xcodegen` before every build on the Mac: `scripts/mac.sh` rsyncs with
`--delete`, which removes the generated (gitignored) `Info.plist`.

## Headless self-test

```sh
DJTools.app/Contents/MacOS/DJTools -selfTest <audio> <out dir> \
  -supportDirectory <scratch dir> [-selfTestApollo] [-selfTestSkipStems] [-useFakeEngines]
  [-selfTestAnalyze [-selfTestKeyTag musical|camelot]]
  [-selfTestNormalize [-selfTestTarget -10] [-selfTestCeiling -1]]
  [-selfTestFormat aiff|wav|flac|mp3-320|mp3-256|mp3-192]
```

Runs the quality check, then one Process run through the same adapters and
`ResultWriter.process` the window uses: repair with `-selfTestApollo`
(Apollo installed first if needed), normalize with `-selfTestNormalize`,
htdemucs stems unless `-selfTestSkipStems`, saved as `-selfTestFormat`
(default aiff); each output is decoded again and its rate, length and tags
checked (the finished track's title must be the source's, unsuffixed). A normalized output is also measured again with LoudnessKit and
must land within ±0.2 LU of the target, or on the ceiling (±0.1 dB) when the
plan was capped. With `-selfTestAnalyze` it first detects BPM and key, checks
Apply's only-where-missing rule on a copy (`<out>/apply-check.<ext>`), and
the outputs must carry the source's own BPM / key, else the detected ones.
The step callbacks must enter each of the run's steps once,
in order. Prints one
JSON object (timings, outputs, callback counts and whether any arrived off
the main thread) and exits 0/1. Works in Release, no GUI
session needed; `-supportDirectory` keeps the models out of
`~/Library`. See `Debug/SelfTest.swift`.

## Fakes

`-useFakeEngines` picks them (the Xcode scheme passes it for Run; untick it
there to try the real engines); without it, or with `-useFakeEngines NO`,
the real ones run. The toolbar then shows
"Demo engines". Quality verdicts are deterministic per file name (a name with
"128" reads Low quality, "fake" Fake lossless). Stems and repairs count up for a
few seconds and write one-second silent WAVs where the real ones would write
output. The fake loudness meter makes up a measurement per file name, the fake
analyzer a BPM and key (its first run "downloads the model", marker in
`fake-engines/`); the
normalized copy still goes through the real AudioExport. The fake Apollo "install" leaves a marker in
`App Support/DJTools/fake-engines/`, never in `models/`. `-fakeEngineSpeed 4`
runs them four times faster.

## Previews

`DJTools -renderPreviews <dir>` (Debug) renders the main screens with fixture
data to PNGs and exits, no window or GUI session needed — see
`Debug/PreviewRenderer.swift`.

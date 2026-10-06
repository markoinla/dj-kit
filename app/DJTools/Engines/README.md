# Engines: the seam to the packages

The app talks to the packages only through three protocols in
`EngineProtocols.swift`, using its own copies of the contract types in
`EngineTypes.swift` (`DJQualityReport`, `DJStemModel`, … — same fields and
cases as `docs/CONTRACTS.md`, prefixed `DJ` so nothing clashes). Only
`RealEngines.swift` imports QualityKit, StemsKit and ApolloMLX.

| Protocol | Adapter (`RealEngines.swift`) | Package API |
| --- | --- | --- |
| `QualityChecking` | `QualityKitAdapter` | `QualityAnalyzer.analyze(_:)` |
| `StemSeparating` | `StemsKitAdapter` (actor, one `StemSeparator` per model, kept alive) | `StemSeparator(model:modelsDirectory:).separate(...)` |
| `ApolloRepairing` | `ApolloMLXAdapter` (actor) | `ApolloMLXRepairer(modelsDirectory:)` |
| `ApolloRepairing.reset()` | `removeWeights()` | — |

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

`apollo/` (Python) and `Packages/ApolloBridge` stay in the repo as the
reference implementation; the app no longer links or bundles them.

## Saving results (`Model/ResultWriter.swift`)

The engines write their native 24-bit WAVs into a scratch folder on the
output folder's volume; `AudioExport` converts each to the job's format
(AIFF default, WAV, FLAC, MP3 320/256/192), copies the source's
title/artist/album/artwork (title suffixed " (Vocals)", " (Repaired)", …;
not for WAV) and the scratch folder is deleted however the job ends. Names:
`<out>/<track> (Stems)/<stem>.<ext>` (replacing an older folder) and
`<out>/<track> (Apollo).<ext>` (numbered when taken). The defaults are in
Settings (`AppSettings.stemsFormat` / `repairFormat`); the "Save as" menu
under each tool's button overrides them per job.

`Engines.real(supportDirectory:)` builds them; `supportDirectory` is
`AppPaths.support` (`~/Library/Application Support/DJTools`, or
`-supportDirectory <path>`).

Heavy jobs (stems ~5.4 GB peak footprint, Apollo repairs ~2.9 GB) share one slot in
`AppModel` (`heavyInFlight`), so they never run together.

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
  [-selfTestFormat aiff|wav|flac|mp3-320|mp3-256|mp3-192]
```

Runs quality check, htdemucs stems and (with `-selfTestApollo`) Apollo
install + repair through the same adapters and `ResultWriter` the window
uses, one after the other, saved as `-selfTestFormat` (default aiff); each
output is decoded again and its rate, length and tags checked. Prints one
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
output. The fake Apollo "install" leaves a marker in
`App Support/DJTools/fake-engines/`, never in `models/`. `-fakeEngineSpeed 4`
runs them four times faster.

## Previews

`DJTools -renderPreviews <dir>` (Debug) renders the main screens with fixture
data to PNGs and exits, no window or GUI session needed — see
`Debug/PreviewRenderer.swift`.

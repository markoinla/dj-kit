# dj-tools

Native macOS app (SwiftUI) for DJ track prep: stem separation, Apollo repair of lossy
rips (native MLX port, `Packages/ApolloMLX`; the Python `apollo/` + `ApolloBridge` are kept
only as the reference), a bad-file detector, and loudness normalization (`Packages/LoudnessKit`,
BS.1770-4 / EBU R128, pure gain, writes a new "(Normalized)" file). Results are saved as AIFF (default), WAV,
FLAC or MP3 through `Packages/AudioExport`. Personal use; output goes into Rekordbox by hand.
Rekordbox already does BPM, key and beatgrid, so those are out of scope; its Auto Gain is
playback-only, which is why Normalize exists (it bakes the level into a copy).

- Module seams: `docs/CONTRACTS.md`. Research: `research/`.
- This repo is edited on Linux (a Linux box) and **built on build-mac**:
  `scripts/mac.sh <run-name> '<command>'` rsyncs the repo to `build-mac:~/runs/djt-<run-name>/`
  and runs the command there; `scripts/fetch.sh` copies results back. Use a distinct
  run-name per parallel worker. `agent` has no sudo/brew; stay inside the run dir.
- MLX packages need `xcodebuild` (it compiles the Metal shaders); plain `swift build`
  links but fails at runtime without the metallib.
- Design reference: Wax Studio, `Wax Studio`.
- Signed with Apple Development (team M44R9APYMG, App ID `la.marko.djtools`, ShazamKit + MusicKit App Services). A box without that cert builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` (no Shazam).
- Building MLX code needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`,
  no sudo; already installed on build-mac). Don't run stems and Apollo together on a 16 GB Mac:
  stems peak around 5.4 GB, Apollo around 2.9 GB, and the box swaps hard.
- Run `xcodegen` before every app build on the Mac: `scripts/mac.sh` rsyncs with `--delete`,
  which removes the generated (gitignored) `app/DJTools/Info.plist`.

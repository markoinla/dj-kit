# dj-kit

Native macOS app (SwiftUI) for DJ track prep: stem separation, Apollo repair of lossy
rips (native MLX port, `Packages/ApolloMLX`; the Python `apollo/` + `ApolloBridge` are kept
only as the reference), a bad-file detector, loudness normalization (`Packages/LoudnessKit`,
BS.1770-4 / EBU R128, pure gain), and BPM / key detection (`Packages/AnalysisKit`). One Process run per track does repair → normalize → stems and
saves once ("Artist - Title.aiff", no suffix; steps in the comment tag). Results are saved as AIFF (default), WAV,
FLAC or MP3 through `Packages/AudioExport`. UI copy stays minimal: labels, no explanations. Personal use; output goes into Rekordbox by hand.
BPM / key are optional (libkeyfinder + Beat This! on MLX) and only fill tags a file doesn't
already have; beatgrid stays Rekordbox's. Rekordbox's Auto Gain is
playback-only, which is why Normalize exists (it bakes the level into a copy).

- Module seams: `docs/CONTRACTS.md`. Research: `research/`.
- Releases: `scripts/release.sh --publish <version>` (`RELEASING.md`): Developer ID, notarized DMG on
  GitHub Releases; Sparkle's feed is the latest release's `appcast.xml`. Updater off in Debug.
- Build hosts, signing and release credentials: `CLAUDE.local.md` (gitignored; the repo is public).
- MLX packages need `xcodebuild` (it compiles the Metal shaders); plain `swift build`
  links but fails at runtime without the metallib.
- Design reference: Wax Studio (a separate app; path in `CLAUDE.local.md`).
- Signed with Apple Development (App ID `la.marko.djtools`, kept from the old name "DJ Tools"; ShazamKit + MusicKit App Services). A box without that cert builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` (no Shazam).
- Building MLX code needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`,
  no sudo). Don't run stems and Apollo together on a 16 GB Mac:
  stems peak around 5.4 GB, Apollo around 2.9 GB, and the box swaps hard.
- Run `xcodegen` before every app build: it generates the (gitignored) `app/DJKit/Info.plist`
  and `DJKit.xcodeproj`.

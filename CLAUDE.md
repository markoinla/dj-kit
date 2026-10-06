# dj-tools

Native macOS app (SwiftUI) for DJ track prep: stem separation, Apollo repair of lossy
rips, and a bad-file detector. Personal use; output goes into Rekordbox by hand.
Rekordbox already does BPM, key, beatgrid and gain, so those are out of scope.

- Module seams: `docs/CONTRACTS.md`. Research: `research/`.
- This repo is edited on Linux (a Linux box) and **built on build-mac**:
  `scripts/mac.sh <run-name> '<command>'` rsyncs the repo to `build-mac:~/runs/djt-<run-name>/`
  and runs the command there; `scripts/fetch.sh` copies results back. Use a distinct
  run-name per parallel worker. `agent` has no sudo/brew; stay inside the run dir.
- MLX packages need `xcodebuild` (it compiles the Metal shaders); plain `swift build`
  links but fails at runtime without the metallib.
- Design reference: Wax Studio, `Wax Studio`.
- No signing yet.
- Building MLX code needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`,
  no sudo; already installed on build-mac). Don't run stems and Apollo together on a 16 GB Mac:
  each peaks around 6 GB and the box swaps hard.

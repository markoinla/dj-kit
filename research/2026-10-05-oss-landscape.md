# DJ track-prep Mac app — open-source landscape (2026-10-05)

Working name: `dj-tools`. Native macOS app for preparing tracks before they go into
Rekordbox/Serato/Traktor.

## 1. Lossy → "lossless" restoration (the "bitrate fixer")

| Repo | What | Notes |
| --- | --- | --- |
| [JusperLee/Apollo](https://github.com/JusperLee/Apollo) | Band-split model trained to repair MP3-compressed music | Most likely the one Marko saw. Music-specific, best fit. Check weights license. |
| [zbitouzakaria/grooveback](https://github.com/zbitouzakaria/grooveback) | Built on Apollo, aimed at rare records that only exist as bad rips | Very on-theme for DJs digging old tracks. |
| [haoheliu/versatile_audio_super_resolution](https://github.com/haoheliu/versatile_audio_super_resolution) (AudioSR) | Diffusion upsampler, any audio → 48 kHz | Well known, slow (diffusion). Better for low-samplerate than for MP3 artifacts. |
| [AEROMamba-PAQM](https://aeromamba-paqm.github.io/) | Efficient SR w/ psychoacoustic loss | Claimed to beat AudioSR; newer, less tooling. |

Reality check: these *reconstruct plausible* highs, they don't recover the original.
Good for 128k rips; a 320k MP3 is already near-transparent. A "fake FLAC detector"
(spectrogram cutoff check) is a cheap, honest companion feature.

## 2. Stem separation

- **Models:** HTDemucs / htdemucs_ft (Meta, MIT) is the safe default; BS-RoFormer /
  Mel-RoFormer are SOTA for vocals (~+0.8 dB SDR), slower.
- **Mac-native ports (big deal for a Mac app, no Python needed):**
  - [ssmall256/demucs-mlx-swift](https://github.com/ssmall256/demucs-mlx-swift) — Swift 6, MLX, Apple audio I/O
  - [ssmall256/mlx-audio-separator](https://github.com/ssmall256/mlx-audio-separator) — Demucs + MDX + RoFormer on MLX
  - [gwenn-ha-dev/Quatuor](https://github.com/gwenn-ha-dev/Quatuor) — existing native macOS stem app (reference/competitor)
- **Python route:** [nomadkaraoke/python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) wraps UVR's whole model zoo.

## 3. BPM / beatgrid / key / structure

| Repo | Gives you | License |
| --- | --- | --- |
| [CPJKU/beat_this](https://github.com/CPJKU/beat_this) | SOTA beats + downbeats (ISMIR 2024). Has C++ and Rust ports | MIT |
| [mir-aidj/all-in-one](https://github.com/mir-aidj/all-in-one) | BPM, beats, downbeats, **segments labelled intro/verse/chorus/outro**. MLX port: [ssmall256/all-in-one-mlx](https://github.com/ssmall256/all-in-one-mlx) | MIT |
| [MTG/essentia](https://github.com/MTG/essentia) | Swiss-army MIR: BPM, key, loudness, danceability, mood/genre models | **AGPL** |
| [mixxxdj/libkeyfinder](https://github.com/mixxxdj/libkeyfinder) | Key detection (what Mixxx uses) | **GPL** |

License flag: Essentia/libkeyfinder are copyleft. Fine for personal/open-source;
problem if the app is ever sold closed-source.

## Feature ideas (beyond the three asked about)

- **Auto cue points from structure** — all-in-one segments → hot cues at drop/breakdown/outro, written into the DJ library.
- **Library writeback** — export to Rekordbox XML / Serato tags / Traktor NML. This is the real moat; analysis alone is commodity.
- **Quality triage** — scan a folder, flag low-bitrate & fake-FLACs, offer one-click Apollo repair.
- **Loudness normalize** (EBU R128) and true-peak check.
- **DJ edits from stems** — acapella/instrumental exports, extended intros built from drum stem.
- **Harmonic mixing helper** — Camelot wheel, "what mixes into this".
- **Dupe finder** via audio fingerprint (chromaprint).

## Architecture sketch

SwiftUI app; analysis in MLX/Swift where ports exist (Demucs, all-in-one), Python
sidecar (bundled via uv) for the rest (Apollo, Essentia). Watch-folder + queue.
Can't build Mac apps on homelab-omarchy — use mac-ci / homelab-mbp.

## Related

`~/Projects/wax-audio` (DJ show archive, has track ID + iOS client) could share the
analysis engine later.

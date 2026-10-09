# DJ Kit

Native macOS app for preparing tracks: separate stems (Demucs on MLX), repair lossy rips
(Apollo), and flag low-quality or fake-lossless files. macOS 14.4+, Apple Silicon.

Headless, for scripts and agents: `DJKit.app/Contents/MacOS/DJKit -help` (check, tags,
loudness, analyze, identify, tag, process; JSON lines out). Agents: `.claude/skills/djkit`.

See `CLAUDE.md` for how it's built and `docs/CONTRACTS.md` for the module layout.

## Download

[DJ-Kit.dmg](https://github.com/markoinla/dj-kit/releases/latest/download/DJ-Kit.dmg): signed and
notarized, Apple Silicon, macOS 14.4+. Updates itself (Sparkle). Models (Demucs, Apollo, Beat This!)
download on first use. Stems and Apollo need a lot of memory: on a 16 GB Mac, run one at a time.

Releasing: `RELEASING.md`.

## License

GPL-3.0 (`LICENSE`), because DJ Kit ships libkeyfinder. Some parts carry their own licenses:
`Packages/ApolloMLX` and `apollo/` are CC BY-SA 4.0 (Apollo), LAME in `Packages/AudioExport` is
LGPL. The full list is in the app under Settings ▸ Credits.

# DJ Kit

Native macOS app for preparing tracks: separate stems (Demucs on MLX), repair lossy rips
(Apollo), and flag low-quality or fake-lossless files. macOS 14.4+, Apple Silicon.

Headless, for scripts and agents: `DJKit.app/Contents/MacOS/DJKit -help` (check, tags,
loudness, analyze, identify, tag, process; JSON lines out). Agents: `.claude/skills/djkit`.

See `CLAUDE.md` for how it's built and `docs/CONTRACTS.md` for the module layout.

---
name: djkit
description: Bulk music-file work with the DJ Kit app, headless — check for bad / fake-lossless rips, read or set tags, measure loudness, detect BPM and key, identify tracks (Shazam + Apple Music) and tag / rename them, and Process (Apollo repair, loudness normalize, Demucs stems) into new files. Use when asked to sort, clean up, tag, identify, analyze or prep audio files (mp3, m4a, flac, wav, aiff) for DJing or Rekordbox.
---

# DJ Kit, headless

The app's own binary runs one command on files without opening a window.

Find it (the app may live anywhere):

```sh
for app in /Applications/DJKit.app ~/Applications/DJKit.app \
    "$(mdfind 'kMDItemCFBundleIdentifier == la.marko.djtools' 2>/dev/null | head -1)" \
    ~/Desktop/PROJECTS/TOOLS/dj-kit/app/build/Build/Products/Debug/DJKit.app; do
  [ -x "$app/Contents/MacOS/DJKit" ] && DJKIT="$app/Contents/MacOS/DJKit" && break
done
```

**Run `"$DJKIT" -help` first**, then `"$DJKIT" -help <command>` for one command's
options and output fields. The help is the reference; this file is only the habits.

- stdout: one JSON object per file (`ok`, `error`, fields), then a `summary` line.
  Progress is on stderr; discard it (`2>/dev/null`) unless something fails.
- Exit 0: every file worked; 1: some failed (look for `"ok":false`); 64: bad usage
  (the message says what's wrong).
- Read-only first: `check`, `tags`, `loudness`, `analyze` / `identify` without `-apply`.
- Before writing in bulk (`tag`, `-apply`, `-rename`): run once with `-dryRun`, show
  the user what would change, and get a yes.
- `identify -apply` only applies strong matches whose length fits; `skipped` says
  why one wasn't. Don't reach for `-applyWeak` without asking.
- `process` writes new files to `-out` (default: the app's output folder) and never
  changes the source. Repair and stems are slow and use several GB each; files go one
  at a time. Don't start two DJ Kit runs at once.
- It never touches the app window's track list; renamed files show as missing there.

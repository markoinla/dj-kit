# CLAME: vendored LAME 3.100 (libmp3lame encoder)

LAME is free software under the GNU Lesser General Public License, version 2 or
later (see `COPYING`; LAME's own notes in `LICENSE`). https://lame.sourceforge.io

- Source: `lame-3.100.tar.gz` from
  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
  (checked when vendored).
- Copied unmodified: `include/lame.h`, every `libmp3lame/*.c` and `*.h`, and
  `libmp3lame/vector/lame_intrin.h` (header only; `fft.c` includes it). `COPYING`
  and `LICENSE` from the tarball root.
- Left out: the frontend, mpglib (decoder), the SSE/NASM code (`vector/*.c`,
  `i386/`), build files.
- Added: `config.h` (hand-written stand-in for autoconf's, for arm64 macOS).

AudioExport uses it only to encode MP3: CBR, joint stereo, `-q 0`, 44.1 kHz.
To update, replace the files above from a new release tarball and check its hash.

# CKeyFinder: vendored libkeyfinder 2.2.8

libkeyfinder (Ibrahim Sha'ath, maintained by Mixxx) is free software under the GNU
General Public License, version 3 or later (see `LICENSE`). https://github.com/mixxxdj/libkeyfinder

- Source: tag `2.2.8` (latest release), commit `b33b5a88e04a5182dd19c38c57762925631118fd`,
  https://github.com/mixxxdj/libkeyfinder/archive/refs/tags/2.2.8.tar.gz
  (SHA-256 `a54fc6c5ff435bb4b447f175bc97f9081fb5abf0edd5d125e6f5215c8fff4d11`).
- Copied: every `src/*.cpp` and `src/*.h` into `libkeyfinder/`; `LICENSE`.
- Left out: tests, examples, docs, CMake and packaging files.
- Patched (each marked `dj-tools:`):
  - `fftadapter.cpp`: FFTW replaced by vDSP's double-precision complex DFT. Same
    contract: forward is unnormalised r2c (bins above n / 2 read as zero), inverse is
    c2r from bins 0…n / 2, `getOutput` divides by n. Checked against a naive DFT in
    `KeyDetectorTests` (`KeyFFTTests`).
  - `lowpassfilter.cpp`: the sample-by-sample FIR delay line replaced by
    `vDSP_desampD` on a zero-padded copy; same outputs (within 1 ulp-level rounding,
    checked against the original loop); 6 min at 44.1 kHz goes from ~0.5 s to ~0.37 s.
  - `keyclassifier.{h,cpp}`: `classify` takes an optional `outScores` vector for the
    24 cosine scores, so the shim can report a confidence margin.
  - `lowpassfilterfactory.cpp`, `chromatransformfactory.cpp`, `temporalwindowfactory.cpp`:
    each `get*` holds the factory's mutex for the whole lookup (`std::lock_guard`), not just
    the insert. Upstream scanned the vector unlocked while another thread could `push_back`
    (reallocation: use-after-free) and read freshly built filters without a happens-before.
  - `constants.cpp`: `toneProfileMajor/Minor` build their vectors in a function-local static
    (thread-safe initialisation) instead of filling globals on first use unlocked.
  - Both found with ThreadSanitizer: 8 threads calling `ckf_detect` at once (same rate and
    different rates); clean after the patches.
- Added: `CKeyFinder.cpp` + `include/CKeyFinder.h`, the plain C shim AnalysisKit calls.

To update, replace `libkeyfinder/` from a new release and re-apply the patches above.

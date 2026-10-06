# Attribution

This project contains code adapted from **Apollo: Band-sequence Modeling for High-Quality
Audio Restoration** by Kai Li and Yi Luo (Tsinghua University / Tencent AI Lab),
https://github.com/JusperLee/Apollo, upstream commit
`e84bcacc59d5455f05d86a5c97dd4aeb3c14dbb6`. The pretrained weights it downloads are
`JusperLee/Apollo` on Hugging Face (`pytorch_model.bin`). Both are licensed under the
Creative Commons Attribution-ShareAlike 4.0 International License (`LICENSE` here,
https://creativecommons.org/licenses/by-sa/4.0/).

Adapted files, and what changed:

- `src/apollo_repair/model.py` — from `look2hear/models/apollo.py` and
  `look2hear/models/base_model.py`. Only the inference model is kept; the stdout `print`
  in `Apollo.__init__` was removed, the Hugging Face mixin and training helpers were
  dropped, and checkpoint loading was rewritten as `load_apollo()`.
- `src/apollo_repair/chunking.py` — the chunked, padded, crossfaded overlap-add from
  upstream `inference.py`, restructured as a generator that reports per-chunk progress.

As required by the ShareAlike term, these adapted files are distributed under
CC BY-SA 4.0 as well.

```bibtex
@inproceedings{li2025apollo,
  title={Apollo: Band-sequence Modeling for High-Quality Music Restoration in Compressed Audio},
  author={Li, Kai and Luo, Yi},
  booktitle={IEEE International Conference on Acoustics, Speech and Signal Processing (ICASSP)},
  year={2025},
  organization={IEEE}
}
```

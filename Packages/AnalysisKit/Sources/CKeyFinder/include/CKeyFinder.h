// C shim over the vendored libkeyfinder (see VENDORED.md).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// ckf_detect / ckf_scores results.
enum {
  CKF_KEY = 0,      ///< outputs filled
  CKF_NO_KEY = 1,   ///< silence (or near it): nothing to classify
  CKF_ERROR = -1,   ///< bad arguments or an internal failure
};

/// Key of mono float audio at 4.4 kHz or above (libkeyfinder low-passes and
/// decimates to about 4.4 kHz itself). `outTonic`: 0 = C … 11 = B.
/// `outMargin`: (best − runner-up) / (best − worst) of the 24 cosine scores, 0…1.
int ckf_detect(const float *mono, size_t count, double sampleRate,
               int *outTonic, int *outIsMinor, double *outMargin);

/// Same analysis, all 24 cosine scores at index tonic * 2 + isMinor.
int ckf_scores(const float *mono, size_t count, double sampleRate, double outScores[24]);

/// For tests: libkeyfinder's FFT adapters (FFTW r2c / c2r semantics, vDSP inside).
/// Forward: `n` real samples in, `n` bins out (above n / 2 zero), unnormalised.
int ckf_test_forward_fft(const double *input, unsigned n, double *outReal, double *outImag);
/// Inverse: bins 0…n / 2 used, `n` real samples out, divided by n.
int ckf_test_inverse_fft(const double *inReal, const double *inImag, unsigned n, double *output);

#ifdef __cplusplus
}
#endif

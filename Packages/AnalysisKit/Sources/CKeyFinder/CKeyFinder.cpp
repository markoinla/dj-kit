#include "CKeyFinder.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "libkeyfinder/keyfinder.h"

namespace {

// libkeyfinder keeps samples in a deque<double>; feed it in pieces to bound memory.
// Each piece restarts its low-pass delay line (as in Mixxx's streaming use).
constexpr size_t kChunkFrames = 1 << 21;
// Below about −100 dBFS RMS there's nothing to hear: no key.
constexpr double kSilenceMeanSquare = 1e-10;

KeyFinder::KeyFinder &sharedFinder() {
  // Its filter / kernel / window caches are mutex-guarded, so one instance serves all threads.
  static KeyFinder::KeyFinder finder;
  return finder;
}

/// key_t (A major = 0, A minor, B♭ major, …) to pitch class with C = 0.
int tonicOf(int key) { return (9 + key / 2) % 12; }

int scoresOf(const float *mono, size_t count, double sampleRate, double out[24]) {
  if (count > 0 && mono == nullptr) return CKF_ERROR;
  // The decimation factor floor(rate / 2 / (B6 × 1.1)) must be at least 1.
  if (!(sampleRate >= 4400 && sampleRate <= 768000)) return CKF_ERROR;
  if (count == 0) return CKF_NO_KEY;

  double sumSquares = 0;
  for (size_t i = 0; i < count; i++) {
    float s = mono[i];
    if (std::isfinite(s)) sumSquares += double(s) * double(s);
  }
  if (sumSquares / double(count) < kSilenceMeanSquare) return CKF_NO_KEY;

  try {
    KeyFinder::KeyFinder &finder = sharedFinder();
    KeyFinder::Workspace workspace;
    unsigned int rate = (unsigned int)std::lround(sampleRate);
    for (size_t start = 0; start < count; start += kChunkFrames) {
      size_t n = std::min(kChunkFrames, count - start);
      KeyFinder::AudioData audio;
      audio.setFrameRate(rate);
      audio.setChannels(1);
      audio.addToSampleCount((unsigned int)n);
      for (size_t i = 0; i < n; i++) {
        float s = mono[start + i];
        audio.setSample((unsigned int)i, std::isfinite(s) ? s : 0.0);
      }
      finder.progressiveChromagram(audio, workspace);
    }
    finder.finalChromagram(workspace);

    KeyFinder::KeyClassifier classifier(KeyFinder::toneProfileMajor(), KeyFinder::toneProfileMinor());
    std::vector<double> scores;
    KeyFinder::key_t key = classifier.classify(workspace.chromagram->collapseToOneHop(), &scores);
    if (key == KeyFinder::SILENCE) return CKF_NO_KEY;
    for (int k = 0; k < 24; k++) out[tonicOf(k) * 2 + k % 2] = scores[k];
    return CKF_KEY;
  } catch (...) {
    return CKF_ERROR;
  }
}

}  // namespace

extern "C" int ckf_scores(const float *mono, size_t count, double sampleRate, double outScores[24]) {
  if (outScores == nullptr) return CKF_ERROR;
  return scoresOf(mono, count, sampleRate, outScores);
}

extern "C" int ckf_detect(const float *mono, size_t count, double sampleRate,
                          int *outTonic, int *outIsMinor, double *outMargin) {
  double scores[24];
  int result = scoresOf(mono, count, sampleRate, scores);
  if (result != CKF_KEY) return result;
  int best = 0;
  for (int i = 1; i < 24; i++)
    if (scores[i] > scores[best]) best = i;
  double runnerUp = -1, worst = scores[best];
  for (int i = 0; i < 24; i++) {
    if (i != best) runnerUp = std::max(runnerUp, scores[i]);
    worst = std::min(worst, scores[i]);
  }
  // All-positive chroma makes every cosine score high; the spread is what carries the key.
  double spread = scores[best] - worst;
  double margin = spread > 0 ? (scores[best] - runnerUp) / spread : 0;
  if (outTonic) *outTonic = best / 2;
  if (outIsMinor) *outIsMinor = best % 2;
  if (outMargin) *outMargin = std::min(1.0, std::max(0.0, margin));
  return CKF_KEY;
}

extern "C" int ckf_test_forward_fft(const double *input, unsigned n, double *outReal, double *outImag) {
  try {
    KeyFinder::FftAdapter fft(n);
    for (unsigned i = 0; i < n; i++) fft.setInput(i, input[i]);
    fft.execute();
    for (unsigned i = 0; i < n; i++) {
      outReal[i] = fft.getOutputReal(i);
      outImag[i] = fft.getOutputImaginary(i);
    }
    return 0;
  } catch (...) {
    return CKF_ERROR;
  }
}

extern "C" int ckf_test_inverse_fft(const double *inReal, const double *inImag, unsigned n, double *output) {
  try {
    KeyFinder::InverseFftAdapter fft(n);
    for (unsigned i = 0; i < n; i++) fft.setInput(i, inReal[i], inImag[i]);
    fft.execute();
    for (unsigned i = 0; i < n; i++) output[i] = fft.getOutput(i);
    return 0;
  } catch (...) {
    return CKF_ERROR;
  }
}

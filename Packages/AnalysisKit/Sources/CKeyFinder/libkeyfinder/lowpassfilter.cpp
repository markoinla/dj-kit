/*************************************************************************

  Copyright 2011-2015 Ibrahim Sha'ath

  This file is part of LibKeyFinder.

  LibKeyFinder is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  LibKeyFinder is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with LibKeyFinder.  If not, see <http://www.gnu.org/licenses/>.

*************************************************************************/

/*************************************************************************

  The low pass filter implementation is based on the work of Tony Fisher,
  as shown at http://www-users.cs.york.ac.uk/~fisher/mkfilter/

*************************************************************************/

#include "lowpassfilter.h"

// implementation specific
#include "fftadapter.h"
#include "windowfunctions.h"
#include <Accelerate/Accelerate.h>

namespace KeyFinder {

  class LowPassFilterPrivate {
  public:
    LowPassFilterPrivate(unsigned int order, unsigned int frameRate, double cornerFrequency, unsigned int fftFrameSize);
    void filter(AudioData& audio, Workspace& workspace, unsigned int shortcutFactor = 1) const;
    unsigned int order;
    unsigned int delay;         // always order / 2
    unsigned int impulseLength; // always order + 1
    double gain;
    std::vector<double> coefficients;
  };

  LowPassFilter::LowPassFilter(unsigned int order, unsigned int frameRate, double cornerFrequency, unsigned int fftFrameSize) {
    priv = new LowPassFilterPrivate(order, frameRate, cornerFrequency, fftFrameSize);
  }

  LowPassFilter::~LowPassFilter() {
    if (priv != nullptr) {
      delete priv;
    }
  }

  void LowPassFilter::filter(AudioData& audio, Workspace& workspace, unsigned int shortcutFactor) const {
    priv->filter(audio, workspace, shortcutFactor);
  }

  void const * LowPassFilter::getCoefficients() const {
    return &priv->coefficients;
  }

  LowPassFilterPrivate::LowPassFilterPrivate(unsigned int inOrder, unsigned int frameRate, double cornerFrequency, unsigned int fftFrameSize) {
    if (inOrder % 2 != 0) {
      throw Exception("LPF order must be an even number");
    }
    if (inOrder > fftFrameSize / 4) {
      throw Exception("LPF order must be <= FFT frame size / 4");
    }
    order = inOrder;
    delay = order / 2;
    impulseLength = order + 1;
    double cutoffPoint = cornerFrequency / frameRate;
    InverseFftAdapter* ifft = new InverseFftAdapter(fftFrameSize);

    // Build frequency domain response
    double tau = 0.5 / cutoffPoint;
    for (unsigned int i = 0; i < fftFrameSize/2; i++) {
      double input = 0.0;
      if (i / (double) fftFrameSize <= cutoffPoint) {
        input = tau;
      }
      ifft->setInput(i, input, 0.0);
      ifft->setInput(fftFrameSize - i - 1, input, 0.0);
    }

    // inverse FFT to determine time-domain response
    ifft->execute();

    // TODO determine whether to handle bad_alloc
    coefficients.resize(impulseLength, 0.0);
    unsigned int centre = order / 2;
    gain = 0.0;
    WindowFunction win;

    for (unsigned int i = 0; i < impulseLength; i++) {
      // Grabbing the very end and the very beginning of the real FFT output?
      unsigned int index = (fftFrameSize - centre + i) % fftFrameSize;
      double coeff = ifft->getOutput(index);
      coeff *= win.window(WINDOW_HAMMING, i, impulseLength);
      coefficients[i] = coeff;
      gain += coeff;
    }

    delete ifft;
  }

  // dj-tools: the same FIR as the original sample-by-sample delay line (output o =
  // sum_j coefficients[j] * (input[o - delay + j] / gain), zero outside the input,
  // computed only where o % shortcutFactor == 0 and written in place there), done
  // with vDSP_desampD over a zero-padded copy. Same values up to summation order.
  void LowPassFilterPrivate::filter(AudioData& audio, Workspace& workspace, unsigned int shortcutFactor) const {

    if (audio.getChannels() > 1) {
      throw Exception("Monophonic audio only");
    }
    (void)workspace;

    unsigned int sampleCount = audio.getSampleCount();
    if (sampleCount == 0) {
      return;
    }
    if (shortcutFactor < 1) {
      shortcutFactor = 1;
    }

    std::vector<double> padded(delay + sampleCount + delay, 0.0);
    audio.resetIterators();
    for (unsigned int i = 0; i < sampleCount; i++) {
      padded[delay + i] = audio.getSampleAtReadIterator() / gain;
      audio.advanceReadIterator();
    }

    unsigned int outputCount = (sampleCount + shortcutFactor - 1) / shortcutFactor;
    std::vector<double> output(outputCount);
    vDSP_desampD(padded.data(), shortcutFactor, coefficients.data(), output.data(), outputCount, impulseLength);

    audio.resetIterators();
    for (unsigned int i = 0; i < outputCount; i++) {
      audio.setSampleAtWriteIterator(output[i]);
      if (i + 1 < outputCount) {
        audio.advanceWriteIterator(shortcutFactor);
      }
    }
  }

}

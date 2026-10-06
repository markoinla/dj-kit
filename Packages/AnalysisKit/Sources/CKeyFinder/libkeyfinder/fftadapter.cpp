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

#include "fftadapter.h"

// dj-tools: FFTW replaced by Accelerate (vDSP complex DFT, double precision).
// Same contract as the FFTW version: forward is an unnormalised r2c transform
// whose bins above frameSize / 2 read as zero; inverse is c2r (only bins
// 0...frameSize / 2 are used, Hermitian symmetry assumed, imaginary parts of
// DC and Nyquist ignored) and getOutput divides by frameSize.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>
#include <Accelerate/Accelerate.h>

namespace KeyFinder {

  class FftAdapterPrivate {
  public:
    vDSP_DFT_SetupD setup;
    std::vector<double> inReal, inImag, outReal, outImag;
  };

  FftAdapter::FftAdapter(unsigned int inFrameSize) : priv(new FftAdapterPrivate) {
    frameSize = inFrameSize;
    priv->setup = vDSP_DFT_zop_CreateSetupD(NULL, frameSize, vDSP_DFT_FORWARD);
    if (priv->setup == NULL) {
      delete priv;
      throw Exception("Unsupported FFT frame size");
    }
    priv->inReal.assign(frameSize, 0.0);
    priv->inImag.assign(frameSize, 0.0);
    priv->outReal.assign(frameSize, 0.0);
    priv->outImag.assign(frameSize, 0.0);
  }

  FftAdapter::~FftAdapter() {
    vDSP_DFT_DestroySetupD(priv->setup);
    delete priv;
  }

  unsigned int FftAdapter::getFrameSize() const {
    return frameSize;
  }

  void FftAdapter::setInput(unsigned int i, double real) {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot set out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    if (!std::isfinite(real)) {
      throw Exception("Cannot set sample to NaN");
    }
    priv->inReal[i] = real;
  }

  double FftAdapter::getOutputReal(unsigned int i) const {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot get out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    return priv->outReal[i];
  }

  double FftAdapter::getOutputImaginary(unsigned int i) const {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot get out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    return priv->outImag[i];
  }

  double FftAdapter::getOutputMagnitude(unsigned int i) const {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot get out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    return sqrt( pow(getOutputReal(i), 2) + pow(getOutputImaginary(i), 2) );
  }

  void FftAdapter::execute() {
    vDSP_DFT_ExecuteD(priv->setup, priv->inReal.data(), priv->inImag.data(), priv->outReal.data(), priv->outImag.data());
    // r2c writes bins 0...frameSize / 2 only; the rest stayed zero under FFTW.
    unsigned int half = frameSize / 2 + 1;
    std::fill(priv->outReal.begin() + half, priv->outReal.end(), 0.0);
    std::fill(priv->outImag.begin() + half, priv->outImag.end(), 0.0);
  }

  // ================================= INVERSE =================================

  class InverseFftAdapterPrivate {
  public:
    vDSP_DFT_SetupD setup;
    std::vector<double> inReal, inImag, fullReal, fullImag, outReal, outImag;
  };

  InverseFftAdapter::InverseFftAdapter(unsigned int inFrameSize) : priv(new InverseFftAdapterPrivate) {
    frameSize = inFrameSize;
    priv->setup = vDSP_DFT_zop_CreateSetupD(NULL, frameSize, vDSP_DFT_INVERSE);
    if (priv->setup == NULL) {
      delete priv;
      throw Exception("Unsupported FFT frame size");
    }
    priv->inReal.assign(frameSize, 0.0);
    priv->inImag.assign(frameSize, 0.0);
    priv->fullReal.assign(frameSize, 0.0);
    priv->fullImag.assign(frameSize, 0.0);
    priv->outReal.assign(frameSize, 0.0);
    priv->outImag.assign(frameSize, 0.0);
  }

  InverseFftAdapter::~InverseFftAdapter() {
    vDSP_DFT_DestroySetupD(priv->setup);
    delete priv;
  }

  unsigned int InverseFftAdapter::getFrameSize() const {
    return frameSize;
  }

  void InverseFftAdapter::setInput(unsigned int i, double real, double imag) {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot set out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    if (!std::isfinite(real) || !std::isfinite(imag)) {
      throw Exception("Cannot set sample to NaN");
    }
    priv->inReal[i] = real;
    priv->inImag[i] = imag;
  }

  double InverseFftAdapter::getOutput(unsigned int i) const {
    if (i >= frameSize) {
      std::ostringstream ss;
      ss << "Cannot get out-of-bounds sample (" << i << "/" << frameSize << ")";
      throw Exception(ss.str().c_str());
    }
    // divide by frameSize to normalise
    return priv->outReal[i] / frameSize;
  }

  void InverseFftAdapter::execute() {
    // Rebuild the Hermitian spectrum c2r assumes from bins 0...frameSize / 2.
    unsigned int n = frameSize;
    unsigned int half = n / 2;
    priv->fullReal[0] = priv->inReal[0];
    priv->fullImag[0] = 0.0;
    for (unsigned int k = 1; k < (n + 1) / 2; k++) {
      priv->fullReal[k] = priv->inReal[k];
      priv->fullImag[k] = priv->inImag[k];
      priv->fullReal[n - k] = priv->inReal[k];
      priv->fullImag[n - k] = -priv->inImag[k];
    }
    if (n % 2 == 0) {
      priv->fullReal[half] = priv->inReal[half];
      priv->fullImag[half] = 0.0;
    }
    vDSP_DFT_ExecuteD(priv->setup, priv->fullReal.data(), priv->fullImag.data(), priv->outReal.data(), priv->outImag.data());
  }

}

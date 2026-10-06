import Foundation

/// Every tunable number in the detector, in one place.
enum Thresholds {
    // MARK: Sampling
    /// FFT length (2^fftLog2n). 4096 at 44.1 kHz ≈ 10.8 Hz per bin.
    static let fftLog2n = 12
    /// Windows spread across the track.
    static let windowCount = 32
    /// Consecutive FFT frames read per window.
    static let framesPerWindow = 8
    /// Skip this fraction at the start and end (intros/outros are often silent or sparse).
    static let edgeSkipFraction = 0.04
    /// FFT frames quieter than this (RMS, dBFS) are ignored as silence.
    static let silenceRmsDb = -55.0
    /// Need at least this many non-silent FFT frames to say anything.
    static let minUsableFrames = 16

    // MARK: Cutoff detection
    /// Lowest frequency searched for a cliff.
    static let searchMinHz = 4_000.0
    /// The "before" and "after" bands either side of a candidate edge: [f-outer, f-inner] vs [f+inner, f+outer].
    static let edgeInnerHz = 100.0
    static let edgeOuterHz = 600.0
    /// Minimum level drop across the edge to count as a cliff (dB).
    static let cliffDropDb = 18.0
    /// Above the cliff, the spectrum (90th percentile) must stay this far below the pre-edge level.
    static let cliffStaysLowDb = 12.0
    /// Without a cliff, the cutoff is the highest frequency no more than this far below the mid band (dB).
    static let gradualDropDb = 50.0
    /// The mid ("reference") band the gradual cutoff is measured against.
    static let referenceLowHz = 1_000.0
    static let referenceHighHz = 6_000.0
    /// dB floor for log conversion.
    static let floorDb = -200.0

    // MARK: Verdicts
    /// Lossless file whose highs stop below this (with a cliff) is a transcode.
    static let fakeLosslessMaxCutoffHz = 19_500.0
    /// ...or below this fraction of Nyquist, for low-sample-rate files.
    static let fakeLosslessMaxNyquistFraction = 0.88
    /// Lossy file whose highs stop at or below this is low quality.
    static let lowQualityMaxCutoffHz = 16_500.0
    /// Lossy file whose highs reach at least this is good, whatever its average bitrate:
    /// the measured band beats the declared rate (a ~184 kbps VBR MP3 reaching 18.8 kHz is fine).
    static let goodLossyMinCutoffHz = 18_000.0
    /// Lossy file declared below this bitrate is low quality — only used when the cutoff
    /// can't be measured, or falls between `lowQualityMaxCutoffHz` and `goodLossyMinCutoffHz`.
    static let lowQualityMaxBitrateKbps = 192
}

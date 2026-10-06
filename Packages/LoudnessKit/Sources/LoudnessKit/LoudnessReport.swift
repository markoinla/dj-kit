import Foundation

/// A file's loudness, measured per ITU-R BS.1770-4 / EBU R128.
///
/// Silence reads as `-infinity` (integrated loudness when every block is
/// below the −70 LUFS gate; peaks when every sample is zero).
public struct LoudnessReport: Sendable, Codable, Equatable {
    /// Gated integrated loudness (absolute −70 LUFS gate, relative −10 LU gate).
    public var integratedLUFS: Double
    /// Highest true peak over all channels (≥ 4× oversampled), in dBTP.
    public var truePeakDBTP: Double
    /// Highest absolute sample value over all channels, in dBFS.
    public var samplePeakDBFS: Double
    /// EBU Tech 3342 loudness range; nil when the file is shorter than one
    /// 3 s short-term window or everything is gated out.
    public var loudnessRangeLU: Double?
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channels: Int

    public init(integratedLUFS: Double, truePeakDBTP: Double, samplePeakDBFS: Double,
                loudnessRangeLU: Double?, duration: TimeInterval, sampleRate: Double, channels: Int) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.samplePeakDBFS = samplePeakDBFS
        self.loudnessRangeLU = loudnessRangeLU
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Nothing above the absolute gate: there is no loudness to normalize.
    public var isSilent: Bool { !integratedLUFS.isFinite }
}

/// What a pure gain change does to a measured file.
public struct NormalizationPlan: Sendable, Codable, Equatable {
    public var targetLUFS: Double
    public var ceilingDBTP: Double
    /// The gain to apply, in dB (negative: quieter).
    public var gainDB: Double
    /// Reaching the target would have pushed the true peak over the
    /// ceiling, so the gain stops at the ceiling instead.
    public var limitedByCeiling: Bool
    public var resultingLUFS: Double
    public var resultingTruePeakDBTP: Double

    public init(targetLUFS: Double, ceilingDBTP: Double, gainDB: Double, limitedByCeiling: Bool,
                resultingLUFS: Double, resultingTruePeakDBTP: Double) {
        self.targetLUFS = targetLUFS
        self.ceilingDBTP = ceilingDBTP
        self.gainDB = gainDB
        self.limitedByCeiling = limitedByCeiling
        self.resultingLUFS = resultingLUFS
        self.resultingTruePeakDBTP = resultingTruePeakDBTP
    }

    /// The linear factor for `gainDB`.
    public var linearGain: Double { pow(10, gainDB / 20) }
}

/// Loudness normalization by gain alone: no limiter, no compression.
public enum Normalizer {
    /// The gain that brings `report` to `targetLUFS`, unless that would push
    /// its true peak above `ceilingDBTP`: then the gain is whatever puts the
    /// true peak exactly at the ceiling (`limitedByCeiling`), which can be
    /// less than the target asks for, or even a cut when the source already
    /// peaks above the ceiling. A silent file gets 0 dB.
    public static func gain(for report: LoudnessReport, targetLUFS: Double, ceilingDBTP: Double) -> NormalizationPlan {
        guard !report.isSilent else {
            return NormalizationPlan(targetLUFS: targetLUFS, ceilingDBTP: ceilingDBTP, gainDB: 0, limitedByCeiling: false,
                                     resultingLUFS: report.integratedLUFS, resultingTruePeakDBTP: report.truePeakDBTP)
        }
        let wanted = targetLUFS - report.integratedLUFS
        let headroom = ceilingDBTP - report.truePeakDBTP
        // 1e-9: a target that lands exactly on the ceiling isn't "capped".
        let limited = report.truePeakDBTP.isFinite && wanted > headroom + 1e-9
        let gain = limited ? headroom : wanted
        return NormalizationPlan(
            targetLUFS: targetLUFS, ceilingDBTP: ceilingDBTP, gainDB: gain, limitedByCeiling: limited,
            resultingLUFS: report.integratedLUFS + gain,
            resultingTruePeakDBTP: report.truePeakDBTP + gain
        )
    }
}

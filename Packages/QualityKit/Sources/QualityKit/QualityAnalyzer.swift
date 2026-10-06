import AVFoundation
import AudioToolbox
import Foundation

public enum QualityAnalyzer {
    /// Decodes a sample of the file, measures the spectral cutoff and returns a verdict.
    /// Runs off the caller's actor; typically well under a second for a full track.
    public static func analyze(_ url: URL) async throws -> QualityReport {
        let measured = try await Task.detached(priority: .utility) { try measure(url) }.value
        let bitrate = await declaredBitrateKbps(url: url, measured: measured)
        let (verdict, summary) = classify(
            isLossless: measured.isLossless,
            codecLabel: measured.codecLabel,
            bitrateKbps: bitrate,
            cutoff: measured.cutoff,
            sampleRate: measured.sampleRate,
            usableFrames: measured.usableFrames
        )
        return QualityReport(
            url: url,
            container: measured.container,
            isLosslessContainer: measured.isLossless,
            declaredBitrateKbps: bitrate,
            sampleRate: measured.sampleRate,
            channels: measured.channels,
            duration: measured.duration,
            cutoffHz: measured.cutoff.map { ($0.hz / 10).rounded() * 10 },
            verdict: verdict,
            summary: summary
        )
    }

    // MARK: - Measurement

    struct Measurement: Sendable {
        var container: String
        var codecLabel: String
        var isLossless: Bool
        var sampleRate: Double
        var channels: Int
        var duration: TimeInterval
        var cutoff: CutoffEstimate?
        var usableFrames: Int
        var fileBytes: Int64?
    }

    static func measure(_ url: URL) throws -> Measurement {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw QualityError.cannotOpen(url, error.localizedDescription)
        }
        let fmt = file.fileFormat
        let formatID = fmt.streamDescription.pointee.mFormatID
        let sampleRate = fmt.sampleRate
        guard file.length > 0, sampleRate > 0 else { throw QualityError.emptyFile(url) }

        let spectrum = try Spectrum.average(file: file)
        let cutoff = spectrum.usableFrames >= Thresholds.minUsableFrames ? Spectrum.estimateCutoff(spectrum) : nil
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value

        let ext = url.pathExtension.lowercased()
        return Measurement(
            container: ext.isEmpty ? codecName(formatID).lowercased() : ext,
            codecLabel: formatID == kAudioFormatLinearPCM && !ext.isEmpty ? ext.uppercased() : codecName(formatID),
            isLossless: losslessFormats.contains(formatID),
            sampleRate: sampleRate,
            channels: Int(fmt.channelCount),
            duration: Double(file.length) / file.processingFormat.sampleRate,
            cutoff: cutoff,
            usableFrames: spectrum.usableFrames,
            fileBytes: size
        )
    }

    static let losslessFormats: Set<AudioFormatID> = [
        kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC,
    ]

    static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "AAC"
        case kAudioFormatOpus: return "Opus"
        default: return "audio"
        }
    }

    /// Bitrate the file declares (AVAsset's estimated data rate), falling back to size ÷ duration for lossy files.
    static func declaredBitrateKbps(url: URL, measured: Measurement) async -> Int? {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            return Int((Double(rate) / 1000).rounded())
        }
        if !measured.isLossless, let bytes = measured.fileBytes, measured.duration > 1 {
            return Int((Double(bytes) * 8 / measured.duration / 1000).rounded())
        }
        return nil
    }

    // MARK: - Verdict

    static func classify(isLossless: Bool, codecLabel: String, bitrateKbps: Int?, cutoff: CutoffEstimate?,
                         sampleRate: Double, usableFrames: Int) -> (QualityVerdict, String) {
        let nyquist = sampleRate / 2
        guard let cutoff else {
            let why = usableFrames == 0 ? "the track is silent" : "too little audio to measure"
            if !isLossless, let kbps = bitrateKbps, kbps < Thresholds.lowQualityMaxBitrateKbps {
                return (.lowQuality, "\(codecLabel) \(kbps) kbps — low bitrate (spectrum not measured: \(why))")
            }
            return (.unknown, "Can't tell — \(why)")
        }
        let khz = formatKHz(cutoff.hz)

        if isLossless {
            let limit = min(Thresholds.fakeLosslessMaxCutoffHz, nyquist * Thresholds.fakeLosslessMaxNyquistFraction)
            if cutoff.isCliff && cutoff.hz < limit {
                let source = likelySource(cutoff.hz).map { " — likely from a \($0)" } ?? ""
                return (.fakeLossless, "Fake lossless: \(codecLabel) but cuts off at \(khz)\(source)")
            }
            if cutoff.isCliff {
                return (.lossless, "Lossless — highs reach \(khz)")
            }
            return (.lossless, "Lossless — highs reach \(khz), gradual roll-off")
        }

        let label = bitrateKbps.map { "\(codecLabel) \($0) kbps" } ?? codecLabel
        if cutoff.hz <= Thresholds.lowQualityMaxCutoffHz {
            return (.lowQuality, "\(label), cuts off at \(khz) — low quality")
        }
        // The measured band decides; the average bitrate only breaks the tie in the
        // grey zone between the two cutoffs (VBR averages read low on sparse music).
        if cutoff.hz < Thresholds.goodLossyMinCutoffHz,
           let kbps = bitrateKbps, kbps < Thresholds.lowQualityMaxBitrateKbps {
            return (.lowQuality, "\(label) — low bitrate (highs reach \(khz))")
        }
        return (.goodLossy, "\(label), highs reach \(khz) — good")
    }

    /// Rough source bitrate from a lossy encoder's low-pass (LAME/AAC defaults at 44.1 kHz).
    static func likelySource(_ hz: Double) -> String? {
        switch hz {
        case ..<11_500: return "64 kbps or lower lossy file"
        case ..<15_000: return "96–112 kbps lossy file"
        case ..<16_800: return "128 kbps MP3"
        case ..<18_000: return "160 kbps MP3"
        case ..<19_600: return "192 kbps MP3"
        default: return nil
        }
    }

    static func formatKHz(_ hz: Double) -> String {
        String(format: "%.1f kHz", hz / 1000)
    }
}

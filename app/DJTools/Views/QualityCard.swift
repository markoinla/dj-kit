import SwiftUI

/// The quality check in full: the verdict, where the highs stop and the
/// file's facts (Analyze's ⓘ popover).
struct QualityCard: View {
    let report: DJQualityReport
    var fileSize: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DJSpace.md) {
                Image(systemName: report.verdict.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(report.verdict.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                HStack(spacing: DJSpace.sm) {
                    Text(report.summary)
                        .djText(.headline)
                        .foregroundStyle(DJColor.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DJSpace.sm)
                    QualityBadge(verdict: report.verdict, large: true)
                }
            }
            .padding(DJSpace.lg)

            if let cutoff = report.cutoffHz {
                CutoffMeter(cutoffHz: cutoff, nyquist: report.sampleRate / 2, verdict: report.verdict)
                    .padding(.horizontal, DJSpace.lg)
                    .padding(.bottom, DJSpace.lg)
            }

            DJDivider()
            HStack(spacing: 0) {
                fact("Format", formatLabel)
                DJVerticalDivider()
                fact("Bitrate", report.declaredBitrateKbps.map { "\($0) kbps" } ?? "—")
                DJVerticalDivider()
                fact("Sample rate", DJFormat.kHz(report.sampleRate))
                DJVerticalDivider()
                fact("Channels", DJFormat.channels(report.channels))
                DJVerticalDivider()
                fact("Length", DJFormat.duration(report.duration))
                if let fileSize {
                    DJVerticalDivider()
                    fact("Size", DJFormat.bytes(fileSize))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .djCard()
    }

    private var formatLabel: String {
        let name = report.container == "aif" ? "AIFF" : report.container.uppercased()
        return report.isLosslessContainer ? "\(name) · lossless" : name
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).djText(.caption).foregroundStyle(DJColor.mutedForeground).lineLimit(1)
            Text(value)
                .font(.dj(13, weight: 600))
                .monospacedDigit()
                .foregroundStyle(DJColor.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Where the highs stop, on a 0…Nyquist scale with the usual MP3 lowpass
/// points marked (16 kHz ≈ 128 kbps, 19–20 kHz ≈ 256–320 kbps).
struct CutoffMeter: View {
    let cutoffHz: Double
    let nyquist: Double
    let verdict: DJQualityVerdict

    /// Typical MP3 lowpass points (16 kHz ≈ 128 kbps, 20 kHz ≈ 320 kbps).
    private let marks: [(Double, String)] = [(16_000, "128 kbps"), (20_000, "320 kbps")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spectral cutoff")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                Spacer()
                Text(DJFormat.kHz(cutoffHz))
                    .font(.dj(12, weight: 600))
                    .monospacedDigit()
                    .foregroundStyle(DJColor.foreground)
                Text("of \(DJFormat.kHz(nyquist))")
                    .djText(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DJColor.mutedForeground)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DJColor.foreground.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [verdict.tint.opacity(0.35), verdict.tint.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: width * fraction(cutoffHz))
                    ForEach(marks, id: \.0) { mark in
                        Rectangle()
                            .fill(DJColor.foreground.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: width * fraction(mark.0))
                    }
                }
            }
            .frame(height: 10)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Text("0").offset(x: 0)
                    ForEach(marks, id: \.0) { mark in
                        Text(mark.1)
                            .fixedSize()
                            .frame(width: 60)
                            .offset(x: width * fraction(mark.0) - 30)
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DJColor.mutedForeground.opacity(0.8))
            }
            .frame(height: 11)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectral cutoff \(DJFormat.kHz(cutoffHz))")
    }

    private func fraction(_ hz: Double) -> Double {
        guard nyquist > 0 else { return 0 }
        return min(max(hz / nyquist, 0), 1)
    }
}


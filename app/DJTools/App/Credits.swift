import AppKit

/// Third-party work DJ Tools ships or downloads, for Settings ▸ Credits and
/// the About panel. Apollo's CC BY-SA 4.0 requires the attribution.
struct Credit: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let license: String
    let detail: String
    let url: URL
}

enum Credits {
    static let all: [Credit] = [
        Credit(
            name: "Apollo", license: "CC BY-SA 4.0",
            detail: "Repair model and weights by Kai Li and Yi Luo (“Apollo: Band-sequence Modeling for High-Quality Audio Restoration”, ICASSP 2025). Adapted inference code ships under the same license.",
            url: URL(string: "https://github.com/JusperLee/Apollo")!
        ),
        Credit(
            name: "Demucs", license: "MIT",
            detail: "Hybrid Transformer Demucs stem separation models, by Alexandre Défossez and Meta AI Research.",
            url: URL(string: "https://github.com/facebookresearch/demucs")!
        ),
        Credit(
            name: "demucs-mlx-swift", license: "MIT",
            detail: "Demucs ported to MLX Swift, by ssmall256.",
            url: URL(string: "https://github.com/ssmall256/demucs-mlx-swift")!
        ),
        Credit(
            name: "MLX", license: "MIT",
            detail: "Apple's array framework for Apple silicon (mlx, mlx-swift).",
            url: URL(string: "https://github.com/ml-explore/mlx-swift")!
        ),
        Credit(
            name: "LAME", license: "LGPL-2.0",
            detail: "MP3 encoder (libmp3lame 3.100), by the LAME project. Ships unmodified; its source and licence are in Packages/AudioExport.",
            url: URL(string: "https://lame.sourceforge.io")!
        ),
        Credit(
            name: "Manrope", license: "SIL OFL 1.1",
            detail: "Typeface by Mikhail Sharanda.",
            url: URL(string: "https://github.com/sharanda/manrope")!
        ),
    ]

    /// The About panel's credits text.
    @MainActor
    static var attributed: NSAttributedString {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, credit) in all.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n", attributes: body)) }
            text.append(NSAttributedString(string: "\(credit.name) — \(credit.license)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .link: credit.url,
            ]))
            text.append(NSAttributedString(string: credit.detail, attributes: body))
        }
        return text
    }

    @MainActor
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: attributed])
        NSApp.activate()
    }
}

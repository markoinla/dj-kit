import Foundation
import LoudnessKit

// loudness <file>… [--target -10] [--ceiling -1]
// Prints one JSON object per file: the measurement and the normalization plan.

var files: [String] = []
var target = -10.0
var ceiling = -1.0
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--target": target = arguments.next().flatMap(Double.init) ?? target
    case "--ceiling": ceiling = arguments.next().flatMap(Double.init) ?? ceiling
    default: files.append(argument)
    }
}
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("usage: loudness <file>… [--target LUFS] [--ceiling dBTP]\n".utf8))
    exit(64)
}

func rounded(_ value: Double) -> Any {
    value.isFinite ? NSDecimalNumber(string: String(format: "%.2f", value)) : "\(value)"
}

var failed = false
for path in files {
    let url = URL(filePath: path)
    let start = Date()
    do {
        let report = try await LoudnessAnalyzer.measure(url)
        let plan = Normalizer.gain(for: report, targetLUFS: target, ceilingDBTP: ceiling)
        let object: [String: Any] = [
            "file": url.lastPathComponent,
            "integratedLUFS": rounded(report.integratedLUFS),
            "truePeakDBTP": rounded(report.truePeakDBTP),
            "samplePeakDBFS": rounded(report.samplePeakDBFS),
            "loudnessRangeLU": report.loudnessRangeLU.map(rounded) ?? NSNull(),
            "duration": rounded(report.duration),
            "sampleRate": report.sampleRate,
            "channels": report.channels,
            "seconds": rounded(Date().timeIntervalSince(start)),
            "plan": [
                "targetLUFS": target, "ceilingDBTP": ceiling,
                "gainDB": rounded(plan.gainDB), "limitedByCeiling": plan.limitedByCeiling,
                "resultingLUFS": rounded(plan.resultingLUFS),
                "resultingTruePeakDBTP": rounded(plan.resultingTruePeakDBTP),
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        failed = true
        FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
    }
}
exit(failed ? 1 : 0)

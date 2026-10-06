import Foundation
import QualityKit

// Usage: qualitycheck FILE...   — prints one JSON report per file (an array).
let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: qualitycheck FILE...\n".utf8))
    exit(2)
}

struct Failure: Encodable { var path: String; var error: String }
enum Entry: Encodable {
    case report(QualityReport), failure(Failure)
    func encode(to encoder: Encoder) throws {
        switch self {
        case .report(let r): try r.encode(to: encoder)
        case .failure(let f): try f.encode(to: encoder)
        }
    }
}

var entries: [Entry] = []
var failed = false
for path in paths {
    let url = URL(fileURLWithPath: path)
    let start = Date()
    do {
        let report = try await QualityAnalyzer.analyze(url)
        entries.append(.report(report))
        FileHandle.standardError.write(Data(String(format: "%@: %.2fs\n", url.lastPathComponent, Date().timeIntervalSince(start)).utf8))
    } catch {
        failed = true
        entries.append(.failure(Failure(path: path, error: error.localizedDescription)))
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(entries))
FileHandle.standardOutput.write(Data("\n".utf8))
exit(failed ? 1 : 0)

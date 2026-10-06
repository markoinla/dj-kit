import Foundation

/// One line of `apollo-repair`'s JSON-lines stdout protocol.
public enum ApolloEvent: Sendable, Equatable {
  case status(String)
  case progress(Double)
  case done(String)
  case error(String)

  private struct Wire: Decodable {
    var event: String
    var message: String?
    var fraction: Double?
    var output: String?
  }

  /// Parses one protocol line. Returns nil for blank lines, non-JSON, unknown events, or
  /// events missing their field, so stray output can never crash the bridge.
  public static func parse<S: StringProtocol>(_ line: S) -> ApolloEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{", let data = trimmed.data(using: .utf8),
      let wire = try? JSONDecoder().decode(Wire.self, from: data)
    else { return nil }
    switch wire.event {
    case "status": return wire.message.map(ApolloEvent.status)
    case "progress":
      guard let f = wire.fraction, f.isFinite else { return nil }
      return .progress(min(max(f, 0), 1))
    case "done": return wire.output.map(ApolloEvent.done)
    case "error": return .error(wire.message ?? "Unknown error")
    default: return nil
    }
  }
}

/// Splits a byte stream into lines as it arrives. Handles `\n` and `\r\n`, partial lines
/// across reads, and invalid UTF-8 (replaced, never dropped).
struct LineSplitter: Sendable {
  private var buffer = Data()
  /// A line longer than this without a newline is flushed as-is rather than growing forever.
  var maxLineBytes = 1 << 20

  mutating func append(_ data: Data) -> [String] {
    buffer.append(data)
    var lines: [String] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      lines.append(Self.decode(buffer[buffer.startIndex..<nl]))
      buffer.removeSubrange(buffer.startIndex...nl)
    }
    if buffer.count > maxLineBytes {
      lines.append(Self.decode(buffer))
      buffer.removeAll()
    }
    return lines
  }

  /// Returns the trailing unterminated line, if any.
  mutating func finish() -> [String] {
    defer { buffer.removeAll() }
    return buffer.isEmpty ? [] : [Self.decode(buffer)]
  }

  private static func decode(_ bytes: Data) -> String {
    var s = String(decoding: bytes, as: UTF8.self)
    if s.hasSuffix("\r") { s.removeLast() }
    return s
  }
}

import Foundation

/// A major or minor key, written the way Rekordbox shows it.
public struct MusicalKey: Sendable, Codable, Hashable {
  /// Pitch class, 0 = C … 11 = B.
  public var tonic: Int
  public var isMinor: Bool

  public init(tonic: Int, isMinor: Bool) {
    self.tonic = ((tonic % 12) + 12) % 12
    self.isMinor = isMinor
  }

  /// 1…12 on the wheel: 8A = A minor, 8B = C major, one step = a fifth up.
  public var camelotNumber: Int {
    let origin = isMinor ? 8 : 11  // 1A = A♭ minor, 1B = B major
    return ((tonic - origin + 12) % 12) * 7 % 12 + 1
  }

  /// "8A" (minor = A, major = B).
  public var camelot: String { "\(camelotNumber)\(isMinor ? "A" : "B")" }

  /// Rekordbox spelling: "Am", "F#m", "Dbm", "Bb".
  public var musical: String { Self.names[tonic] + (isMinor ? "m" : "") }

  static let names = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

  /// Reads a key tag: musical ("Am", "A minor", "Amin", "A min", "G#m", "A♭m", "F#",
  /// a lone lowercase "a" = minor), Camelot ("8A", "08A", "8a") or Open Key
  /// ("1m" = A minor, "1d" = C major). Nil for anything else.
  public init?(parsing tag: String) {
    let text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = Self.wheel(text) ?? Self.named(text) else { return nil }
    self = key
  }

  /// Camelot "8A" / "8B" or Open Key "1m" / "1d", leading zero allowed.
  private static func wheel(_ text: String) -> MusicalKey? {
    guard let letter = text.last, (2...3).contains(text.count),
      let number = Int(text.dropLast()), (1...12).contains(number),
      text.first?.isNumber == true
    else { return nil }
    let step = (number - 1) * 7
    switch letter.lowercased() {
    case "a": return MusicalKey(tonic: 8 + step, isMinor: true)
    case "b": return MusicalKey(tonic: 11 + step, isMinor: false)
    case "m": return MusicalKey(tonic: 9 + step, isMinor: true)
    case "d": return MusicalKey(tonic: 0 + step, isMinor: false)
    default: return nil
    }
  }

  /// Letter, optional ♯/♭, optional quality word.
  private static func named(_ text: String) -> MusicalKey? {
    var rest = Substring(text)
    guard let letter = rest.first,
      let natural = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11][letter.lowercased()]
    else { return nil }
    rest = rest.dropFirst()
    var tonic = natural
    if let accidental = rest.first {
      switch accidental {
      case "#", "♯": tonic += 1; rest = rest.dropFirst()
      case "b", "♭": tonic -= 1; rest = rest.dropFirst()
      default: break
      }
    }
    let isMinor: Bool
    switch rest.trimmingCharacters(in: .whitespaces).lowercased() {
    case "": isMinor = letter.isLowercase
    case "m", "min", "minor": isMinor = true
    case "maj", "major": isMinor = false
    default: return nil
    }
    return MusicalKey(tonic: tonic, isMinor: isMinor)
  }
}

import Foundation
import Testing
@testable import AnalysisKit

@Suite struct MusicalKeyTests {
  /// Camelot number → (minor, major) in Rekordbox spelling.
  static let wheel: [(String, String)] = [
    ("Abm", "B"), ("Ebm", "F#"), ("Bbm", "Db"), ("Fm", "Ab"), ("Cm", "Eb"), ("Gm", "Bb"),
    ("Dm", "F"), ("Am", "C"), ("Em", "G"), ("Bm", "D"), ("F#m", "A"), ("Dbm", "E"),
  ]

  @Test func camelotAndMusicalForAll24() {
    var seen = Set<String>()
    for tonic in 0..<12 {
      for isMinor in [false, true] {
        let key = MusicalKey(tonic: tonic, isMinor: isMinor)
        let (minor, major) = Self.wheel[key.camelotNumber - 1]
        #expect(key.musical == (isMinor ? minor : major))
        #expect(key.camelot == "\(key.camelotNumber)\(isMinor ? "A" : "B")")
        seen.insert(key.camelot)
      }
    }
    #expect(seen.count == 24)
    #expect(MusicalKey(tonic: 9, isMinor: true).camelot == "8A")
    #expect(MusicalKey(tonic: 0, isMinor: false).camelot == "8B")
    #expect(MusicalKey(tonic: 8, isMinor: true).camelot == "1A")
    #expect(MusicalKey(tonic: 11, isMinor: false).camelot == "1B")
    #expect(MusicalKey(tonic: 1, isMinor: true).camelot == "12A")
    #expect(MusicalKey(tonic: 4, isMinor: false).camelot == "12B")
  }

  @Test func roundTrips() {
    for tonic in 0..<12 {
      for isMinor in [false, true] {
        let key = MusicalKey(tonic: tonic, isMinor: isMinor)
        #expect(MusicalKey(parsing: key.camelot) == key)
        #expect(MusicalKey(parsing: key.musical) == key)
        #expect(MusicalKey(parsing: key.camelot.lowercased()) == key)
        if key.camelotNumber < 10 { #expect(MusicalKey(parsing: "0" + key.camelot) == key) }
        let data = try! JSONEncoder().encode(key)
        #expect(try! JSONDecoder().decode(MusicalKey.self, from: data) == key)
      }
    }
  }

  @Test(arguments: [
    ("Am", "Am"), ("A minor", "Am"), ("Amin", "Am"), ("A min", "Am"), ("a", "Am"),
    ("8A", "Am"), ("08A", "Am"), ("8a", "Am"), (" 8A\n", "Am"), ("  Am ", "Am"),
    ("G#m", "Abm"), ("Abm", "Abm"), ("A♭m", "Abm"), ("ab", "Abm"), ("F#", "F#"),
    ("Gb", "F#"), ("F♯ major", "F#"), ("Fmaj", "F"), ("C", "C"), ("A", "A"), ("Cmajor", "C"),
    ("1m", "Am"), ("1d", "C"), ("01d", "C"), ("2m", "Em"), ("12d", "F"), ("6m", "Abm"), ("7m", "Ebm"),
    ("12A", "Dbm"), ("1B", "B"), ("Cb", "B"), ("E#m", "Fm"), ("bbm", "Bbm"),
    ("C#M", "Db"), ("C#m", "Dbm"), ("AM", "A"), ("Am", "Am"), ("AMIN", "Am"), ("A MAJOR", "A"), ("C#Maj", "Db"),
  ])
  func parses(_ tag: String, _ expected: String) {
    #expect(MusicalKey(parsing: tag)?.musical == expected)
  }

  @Test(arguments: [
    "", " ", "H", "Hm", "13A", "0A", "00A", "8C", "8", "Amm", "A minorx", "1x", "X#m",
    "A##", "8AA", "123A", "o", "Am/8A", "-1A", "A-", "m",
  ])
  func rejects(_ tag: String) {
    #expect(MusicalKey(parsing: tag) == nil)
  }
}

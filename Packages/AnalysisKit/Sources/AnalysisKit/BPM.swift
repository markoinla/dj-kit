// BPM display helpers: the octave range a genre's tempo is folded into, and the tag string.
import Foundation

public enum BPMRange {
  /// House, techno, disco, hip-hop doubled, drum & bass halved… what Rekordbox shows by default.
  public static let standard: ClosedRange<Double> = 88...175
  /// Downtempo genres, where a 90 BPM beat should not read as 180 nor 70 as 140.
  public static let slow: ClosedRange<Double> = 60...120

  /// `slow` for downtempo, trip-hop, chill(out), lounge, reggae, dub and ambient; `standard`
  /// otherwise, including for a missing genre, and for any genre that names a club style too
  /// ("Organic House / Downtempo", "Chill House", "Ambient Techno", "Chillstep", "Dub Techno").
  /// Case-, space- and punctuation-insensitive ("Trip Hop", "trip-hop", "Chill-Out").
  public static func forGenre(_ genre: String?) -> ClosedRange<Double> {
    guard let genre, !genre.isEmpty else { return standard }
    let lower = genre.lowercased()
    let compact = String(lower.unicodeScalars.filter { CharacterSet.letters.contains($0) })
    let club = ["house", "techno", "step", "garage", "bass", "trance", "break", "dnb", "jungle", "electro"]
    // "Electronic(a)" is no style.
    let styles = compact.replacingOccurrences(of: "electronic", with: "")
    if club.contains(where: styles.contains) { return standard }
    if ["downtempo", "triphop", "chill", "lounge", "reggae", "ambient"].contains(where: compact.contains) {
      return slow
    }
    let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
    if words.contains("dub") || words.contains("dubwise") { return slow }
    return standard
  }
}

public enum BPMFormat {
  /// "124" within ±0.05 of a whole number, else one decimal ("123.5").
  public static func string(_ bpm: Double) -> String {
    let whole = bpm.rounded()
    if abs(bpm - whole) <= 0.05 { return String(Int(whole)) }
    return String(format: "%.1f", bpm)
  }
}

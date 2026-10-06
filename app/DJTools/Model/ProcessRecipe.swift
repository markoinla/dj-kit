import AudioExport
import Foundation

/// What one Process run does to a track, in order: repair → normalize →
/// stems, saved once as `format`. The last run's recipe is remembered
/// (`AppSettings.lastRecipe`), except Repair, which starts from the quality
/// check's suggestion every time.
struct ProcessRecipe: Codable, Hashable, Sendable {
    enum Repair: String, Codable, Sendable {
        /// On when the quality check says the file is lossy-sounding.
        case suggested
        case on, off
    }

    var repair: Repair = .suggested
    var normalize = true
    var stems = false
    var stemModel: DJStemModel = .htdemucs
    var stemChoice: DJStemChoice = .all
    // AIFF: lossless, and Rekordbox reads its tags and artwork.
    var format: AudioFileFormat = .aiff

    /// Repair for `track`: `.suggested` follows its quality check.
    func repairs(_ track: Track) -> Bool {
        switch repair {
        case .on: true
        case .off: false
        case .suggested: track.needsRepair
        }
    }

    /// `.suggested` settled for `track` once its quality is known.
    func resolved(for track: Track) -> ProcessRecipe {
        guard repair == .suggested, track.verdict != nil else { return self }
        var copy = self
        copy.repair = track.needsRepair ? .on : .off
        return copy
    }

    /// Runs Apollo or Demucs (possibly: an unresolved suggestion counts).
    var isHeavy: Bool { repair != .off || stems }

    /// "Repair · −10 LUFS · Stems".
    func title(target: DJLoudnessTarget) -> String {
        var steps: [String] = []
        if repair == .on { steps.append("Repair") }
        if normalize { steps.append(DJFormat.lufs(target.lufs, decimals: 0)) }
        if stems { steps.append("Stems") }
        return steps.isEmpty ? "Process" : steps.joined(separator: " · ")
    }
}

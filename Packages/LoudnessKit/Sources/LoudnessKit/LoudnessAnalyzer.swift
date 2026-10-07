import AVFoundation
import Foundation

public enum LoudnessError: LocalizedError, Equatable {
    case cannotOpen(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): "Couldn't read the audio to measure it: \(why)"
        case .empty: "The file has no audio."
        }
    }
}

public enum LoudnessAnalyzer {
    /// Decodes the whole file (anything AVAudioFile reads: MP3, AAC, FLAC,
    /// WAV, AIFF, …) at its own sample rate and measures it. Runs off the
    /// caller's executor; cancelling the calling task stops it. `progress`
    /// (0…1) is called from a background thread.
    ///
    /// Takes roughly a second per few minutes of stereo audio on Apple
    /// silicon, most of it decoding and the true-peak interpolation.
    public static func measure(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessReport {
        let work = Task.detached(priority: .userInitiated) {
            try measureNow(url, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// The synchronous body of `measure`, on the calling thread.
    public static func measureNow(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> LoudnessReport {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw LoudnessError.cannotOpen(error.localizedDescription)
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard file.length > 0, channels > 0, format.sampleRate > 0 else { throw LoudnessError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LoudnessError.cannotOpen("no buffer")
        }
        let meter = LoudnessMeter(sampleRate: format.sampleRate, channelCount: channels)
        let total = Double(file.length)
        var lastReported = -1.0
        progress?(0)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                // Some MP3s overstate their length and fail the last read: within a second of
                // the end, that's the end.
                if file.length - file.framePosition <= AVAudioFramePosition(format.sampleRate) { break }
                throw LoudnessError.cannotOpen(error.localizedDescription)
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw LoudnessError.cannotOpen("not float") }
            meter.process((0..<channels).map { UnsafePointer(data[$0]) }, frameCount: n)
            let fraction = Double(file.framePosition) / total
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                progress?(min(fraction, 1))
            }
        }
        progress?(1)
        return meter.finish()
    }
}

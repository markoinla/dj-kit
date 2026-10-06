import Foundation
import Testing

@testable import StemsKit

@Test func defaultModelsDirectoryIsInAppSupport() {
  let path = StemSeparator.defaultModelsDirectory.path
  #expect(path.hasSuffix("Library/Application Support/DJTools/models"))
}

@Test func modelNames() {
  #expect(StemModel(name: "htdemucs_ft") == .htdemucsFT)
  #expect(StemModel(name: "htdemucs6s") == .htdemucs6s)
  #expect(StemModel(name: "mdx") == nil)
  #expect(StemModel.htdemucs6s.stemNames.count == 6)
  for model in StemModel.allCases { #expect(model.downloadSize > 50_000_000) }
}

@Test func missingInputThrowsWithoutTouchingModels() async throws {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: tmp) }
  let separator = StemSeparator(model: .htdemucs, modelsDirectory: tmp.appendingPathComponent("models"))
  #expect(!separator.isModelDownloaded)
  await #expect(throws: StemsError.self) {
    _ = try await separator.separate(
      input: tmp.appendingPathComponent("nope.wav"), outputDirectory: tmp) { _ in }
  }
  #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("models").path))
}

@Test func cancelledBeforeStartThrowsCancellation() async throws {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: tmp) }
  let separator = StemSeparator(modelsDirectory: tmp)
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await separator.separate(input: URL(fileURLWithPath: "/dev/null"), outputDirectory: tmp) { _ in }
  }
  await #expect(throws: CancellationError.self) { _ = try await task.value }
}

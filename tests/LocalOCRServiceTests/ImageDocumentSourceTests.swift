import Foundation
import LocalOCRCore
@testable import LocalOCRService
import Testing

@Test func imageSourceRejectsCorruptImageDataBeforeRecognition() async {
    await #expect(throws: LocalOCRError.unsupportedFormat("png")) {
        try await ImageDocumentSource().recognize(
            at: fixtureImage(named: "corrupt-image"),
            settings: RecognitionSettings()
        )
    }
}

@Test func imageSourceRejectsFilesWithoutAnImageType() async throws {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
    try Data("plain text".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: LocalOCRError.unsupportedFormat("txt")) {
        try await ImageDocumentSource().recognize(
            at: url,
            settings: RecognitionSettings()
        )
    }
}

private func fixtureImage(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).png")
}

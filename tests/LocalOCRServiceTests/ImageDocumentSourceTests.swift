import CoreGraphics
import Foundation
import ImageIO
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

@Test func imageSourceReadsUnorderedVisionLinesByRowsThenColumns() async throws {
    let source = ImageDocumentSource(recognizer: UnorderedMultilineRecognizer())

    let text = try await source.recognize(
        at: fixtureImage(named: "sample"),
        settings: RecognitionSettings()
    )

    #expect(text == "TOP LEFT\nTOP RIGHT\nBOTTOM LEFT\nBOTTOM RIGHT")
}

private struct UnorderedMultilineRecognizer: TextRecognizing {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        RecognitionCandidate(
            orientation: orientation,
            lines: [
                TextLine(
                    text: "BOTTOM RIGHT",
                    confidence: 1,
                    boundingBox: CGRect(x: 0.65, y: 0.18, width: 0.2, height: 0.1)
                ),
                TextLine(
                    text: "TOP RIGHT",
                    confidence: 1,
                    boundingBox: CGRect(x: 0.65, y: 0.76, width: 0.2, height: 0.1)
                ),
                TextLine(
                    text: "BOTTOM LEFT",
                    confidence: 1,
                    boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
                ),
                TextLine(
                    text: "TOP LEFT",
                    confidence: 1,
                    boundingBox: CGRect(x: 0.1, y: 0.74, width: 0.2, height: 0.1)
                ),
            ]
        )
    }
}

private func fixtureImage(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).png")
}

import CoreGraphics
import Foundation
import ImageIO
@testable import LocalOCRCore
import Testing

@Suite struct VisionTextRecognizerTests {
    @Test func configuresAccurateRecognitionWithRequestedLanguages() {
        let request = VisionTextRecognizer.makeRequest(
            settings: RecognitionSettings(
                recognitionLanguages: ["en-US"],
                usesLanguageCorrection: false
            )
        )

        #expect(request.recognitionLevel == .accurate)
        #expect(request.usesLanguageCorrection == false)
        #expect(request.recognitionLanguages == ["en-US"])
    }

    @Test func mapsVisionFailureToRecognitionFailed() {
        let error = VisionTextRecognizer.recognitionError(VisionFixtureError())

        #expect(error == .recognitionFailed(page: 0, message: "Vision fixture failed"))
    }

    @Test func recognizesUprightSyntheticTextWithRequestedSettings() async throws {
        let image = try fixtureImage(named: "upright-text")
        let settings = RecognitionSettings(
            recognitionLanguages: ["en-US"],
            usesLanguageCorrection: false
        )

        let result = try await VisionTextRecognizer().recognize(
            image: image,
            orientation: .up,
            settings: settings
        )

        #expect(result.orientation == .up)
        #expect(!result.lines.isEmpty)
        #expect(result.text.contains("LOCAL OCR TEST 123"))
        #expect(result.lines.allSatisfy { (0...1).contains($0.confidence) })
        #expect(result.lines.allSatisfy { line in
            line.boundingBox.minX >= 0 && line.boundingBox.minY >= 0 &&
            line.boundingBox.maxX <= 1 && line.boundingBox.maxY <= 1
        })
    }

    @Test func recognizesSidewaysSyntheticTextWithRightOrientation() async throws {
        let image = try fixtureImage(named: "sideways-text")

        let result = try await VisionTextRecognizer().recognize(
            image: image,
            orientation: .right,
            settings: .init(recognitionLanguages: ["en-US"])
        )

        #expect(result.orientation == .right)
        #expect(result.text.contains("LOCAL OCR TEST 123"))
    }
}

private struct VisionFixtureError: LocalizedError {
    var errorDescription: String? { "Vision fixture failed" }
}

private func fixtureImage(named name: String) throws -> CGImage {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

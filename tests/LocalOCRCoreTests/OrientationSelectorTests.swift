import CoreGraphics
import Foundation
import ImageIO
import LocalOCRCore
import Testing

@Suite struct OrientationSelectorTests {
    @Test func retriesWhenUprightScoreIsWeak() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "1", confidence: 0.1),
            .right: candidate(.right, text: "LOCAL OCR TEST 123", confidence: 0.9),
        ])

        let result = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(result.orientation == .right)
        #expect(await recognizer.requestedOrientations == [.up, .right, .down, .left])
    }

    @Test func acceptsStrongUprightCandidateWithoutRetries() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "LOCAL OCR TEST 123", confidence: 0.9),
        ])

        let result = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(result.orientation == .up)
        #expect(await recognizer.requestedOrientations == [.up])
    }

    @Test func exactUprightAcceptanceThresholdAvoidsRetries() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "abcdefghijkl", confidence: 0.55),
        ])

        let result = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(result.orientation == .up)
        #expect(await recognizer.requestedOrientations == [.up])
    }

    @Test func oneCharacterBelowUprightThresholdRetries() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "abcdefghijk", confidence: 0.99),
        ])

        _ = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(await recognizer.requestedOrientations == [.up, .right, .down, .left])
    }

    @Test func confidenceBelowUprightThresholdRetries() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "abcdefghijkl", confidence: 0.549),
        ])

        _ = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(await recognizer.requestedOrientations == [.up, .right, .down, .left])
    }

    @Test func scoreTieKeepsTheFirstUprightCandidate() async throws {
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "a", confidence: 0.5),
            .right: candidate(.right, text: "b", confidence: 0.5),
        ])

        let result = try await OrientationSelector().best(
            image: onePixelImage,
            settings: .init(),
            recognizer: recognizer
        )

        #expect(result.orientation == .up)
        #expect(await recognizer.requestedOrientations == [.up, .right, .down, .left])
    }

    @Test func selectsNonUprightOrientationForSidewaysSyntheticText() async throws {
        let image = try fixtureImage(named: "sideways-text")
        let recognizer = ScriptedTextRecognizer(results: [
            .up: candidate(.up, text: "1", confidence: 0.1),
            .right: candidate(.right, text: "LOCAL OCR TEST 123", confidence: 0.9),
        ])

        let result = try await OrientationSelector().best(
            image: image,
            settings: .init(recognitionLanguages: ["en-US"]),
            recognizer: recognizer
        )

        #expect(result.orientation != .up)
        #expect(result.text.contains("LOCAL OCR TEST 123"))
    }
}

private actor ScriptedTextRecognizer: TextRecognizing {
    private let results: [CGImagePropertyOrientation: RecognitionCandidate]
    private(set) var requestedOrientations: [CGImagePropertyOrientation] = []

    init(results: [CGImagePropertyOrientation: RecognitionCandidate]) {
        self.results = results
    }

    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        requestedOrientations.append(orientation)
        return results[orientation] ?? candidate(orientation, text: "", confidence: 0)
    }
}

private func candidate(
    _ orientation: CGImagePropertyOrientation,
    text: String,
    confidence: Float
) -> RecognitionCandidate {
    RecognitionCandidate(
        orientation: orientation,
        lines: [TextLine(text: text, confidence: confidence, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1))]
    )
}

private let onePixelImage: CGImage = {
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}()

private func fixtureImage(named name: String) throws -> CGImage {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

import Foundation
import ImageIO
import LocalOCRCore
import Testing

@Test func recognitionSettingsRoundTrip() throws {
    let value = RecognitionSettings(
        dpi: 300,
        forceOCR: true,
        recognitionLanguages: ["en-US", "es-ES"],
        usesLanguageCorrection: false
    )

    let decoded = try JSONDecoder().decode(RecognitionSettings.self, from: JSONEncoder().encode(value))

    #expect(decoded == value)
}

@Test func inspectionModelsRoundTrip() throws {
    let value = PDFInspection(
        pages: 2,
        searchablePages: [1],
        ocrNeededPages: [2],
        characters: 66,
        fullySearchable: false,
        pageDetails: [
            PageInspection(page: 1, characters: 66, searchable: true),
            PageInspection(page: 2, characters: 0, searchable: false),
        ]
    )

    let decoded = try JSONDecoder().decode(PDFInspection.self, from: JSONEncoder().encode(value))

    #expect(decoded == value)
}

@Test func pageMethodUsesSnakeCaseRawValues() throws {
    #expect(PageMethod.existingText.rawValue == "existing_text")
    #expect(PageMethod.visionOCR.rawValue == "vision_ocr")
    #expect(try JSONDecoder().decode(PageMethod.self, from: Data("\"vision_ocr\"".utf8)) == .visionOCR)
}

@Test func textLineRoundTrip() throws {
    let value = TextLine(text: "Contract total", confidence: 0.99, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))

    let decoded = try JSONDecoder().decode(TextLine.self, from: JSONEncoder().encode(value))

    #expect(decoded == value)
}

@Test func pageResultRoundTrip() throws {
    let value = PageResult(
        page: 2,
        text: "Retainage withheld",
        method: .visionOCR,
        lines: [TextLine(text: "Retainage withheld", confidence: 0.9, boundingBox: .zero)],
        orientation: .right
    )

    let decoded = try JSONDecoder().decode(PageResult.self, from: JSONEncoder().encode(value))

    #expect(decoded == value)
}

@Test func ocrResultRoundTrip() throws {
    let value = OCRResult(
        sourceSHA256: "abc123",
        pages: [PageResult(page: 1, text: "Native text", method: .existingText, lines: [], orientation: .up)],
        failedPages: [3],
        emptyOCRPages: [4],
        rotatedOCRPages: [2: .left]
    )

    let decoded = try JSONDecoder().decode(OCRResult.self, from: JSONEncoder().encode(value))

    #expect(decoded == value)
}

@Test func requestProgressAndErrorsAreEquatable() {
    let request = OCRRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/source.pdf"),
        pageSelection: "1-3",
        settings: RecognitionSettings()
    )

    #expect(request == OCRRequest(sourceURL: URL(fileURLWithPath: "/tmp/source.pdf"), pageSelection: "1-3", settings: RecognitionSettings()))
    #expect(OCRProgress.recognizing(page: 2, total: 3) == .recognizing(page: 2, total: 3))
    #expect(LocalOCRError.recognitionFailed(page: 2, message: "Vision failed") == .recognitionFailed(page: 2, message: "Vision failed"))
}

@Test func packagedPythonContractFixturesDecodeIntoPublicModels() throws {
    let inspectionURL = try #require(Bundle.module.url(forResource: "inspect_mixed", withExtension: "json", subdirectory: "Fixtures"))
    let inspection = try JSONDecoder().decode(PDFInspection.self, from: Data(contentsOf: inspectionURL))
    let ocrURL = try #require(Bundle.module.url(forResource: "ocr_existing_text", withExtension: "json", subdirectory: "Fixtures"))
    let ocr = try JSONDecoder().decode(OCRResult.self, from: Data(contentsOf: ocrURL))

    #expect(inspection.ocrNeededPages == [2])
    #expect(ocr.pages[0].method == .existingText)
    #expect(ocr.pages[0].orientation == .up)
}

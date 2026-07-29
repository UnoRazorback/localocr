import Foundation
import LocalOCRService
import Testing

@Test func ocrResponseOmitsLinesUnlessRequested() throws {
    let response = PDFOCRResponse.fixture(includeLines: false)
    let object = try #require(
        JSONSerialization.jsonObject(with: ResponseEncoding.encode(response))
            as? [String: Any]
    )
    let page = try #require((object["pages"] as? [[String: Any]])?.first)

    #expect(object["source_path"] as? String == "/tmp/input.pdf")
    #expect(object["failed_pages"] as? [Int] == [])
    #expect(page["method"] as? String == "existing_text")
    #expect(page["lines"] == nil)
}

private extension PDFOCRResponse {
    static func fixture(includeLines: Bool) -> Self {
        PDFOCRResponse(
            sourcePath: "/tmp/input.pdf",
            sourceSHA256: "fixture-sha256",
            pages: [
                OCRPageResponse(
                    page: 1,
                    text: "Existing text",
                    method: .existingText,
                    lines: includeLines ? [
                        OCRLineResponse(
                            text: "Existing text",
                            confidence: 1,
                            x: 0,
                            y: 0,
                            width: 1,
                            height: 1
                        )
                    ] : nil
                )
            ],
            failedPages: [],
            emptyOCRPages: [],
            rotatedOCRPages: []
        )
    }
}

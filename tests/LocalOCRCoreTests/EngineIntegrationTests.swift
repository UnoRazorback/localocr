import Foundation
import LocalOCRCore
import PDFKit
import Testing

@Suite(.serialized) struct EngineIntegrationTests {
    @Test func recognizesSharedImageOnlyFixtureThroughVision() async throws {
        let imageOnlyURL = try #require(
            Bundle.module.url(
                forResource: "image-only",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let result = try await OCRProcessor(
            pdfSource: PDFDocumentSource(),
            recognizer: VisionTextRecognizer(),
            cache: nil
        ).process(
            OCRRequest(
                sourceURL: imageOnlyURL,
                pageSelection: "1",
                settings: RecognitionSettings()
            )
        ) { _ in }

        let page = try #require(result.pages.first)
        #expect(page.method == .visionOCR)
        #expect(
            page.text
                == "Retainage withheld this period totals $144,904.17 exactly"
        )
        #expect(try #require(page.lines.first).confidence > 0)
    }

    @Test func recognizesRotatedImageOnlyPageWithoutClipping() async throws {
        let sourceURL = try #require(
            Bundle.module.url(
                forResource: "image-only",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let directoryURL = URL.temporaryDirectory
            .appendingPathComponent(
                "EngineIntegrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let rotatedURL = directoryURL.appendingPathComponent("rotated.pdf")
        let sourceDocument = try #require(PDFDocument(url: sourceURL))
        let sourcePage = try #require(
            sourceDocument.page(at: 0)?.copy() as? PDFPage
        )
        sourcePage.rotation = 90
        let rotatedDocument = PDFDocument()
        rotatedDocument.insert(sourcePage, at: 0)
        #expect(rotatedDocument.write(to: rotatedURL))

        let result = try await OCRProcessor(
            pdfSource: PDFDocumentSource(),
            recognizer: VisionTextRecognizer(),
            cache: nil
        ).process(
            OCRRequest(
                sourceURL: rotatedURL,
                pageSelection: "1",
                settings: RecognitionSettings()
            )
        ) { _ in }

        #expect(result.failedPages.isEmpty)
        let page = try #require(result.pages.first)
        #expect(page.method == .visionOCR)
        #expect(
            page.text
                == "Retainage withheld this period totals $144,904.17 exactly"
        )
    }

    @Test func exportsSwiftResultsInTheNormalizedPythonContractShape() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "mixed",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let imageOnlyURL = try #require(
            Bundle.module.url(
                forResource: "image-only",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let expectedDirectory = packageRoot
            .appendingPathComponent("tests/contract/expected", isDirectory: true)
        let outputDirectory = packageRoot
            .appendingPathComponent(".build/engine-contracts/swift", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let inspection = try PDFDocumentSource().inspect(fixtureURL)
        var inspectionContract = try dictionary(for: inspection)
        inspectionContract["source_path"] = "<fixture>"
        inspectionContract["source_sha256"] = "<sha256>"

        let processor = OCRProcessor(
            pdfSource: PDFDocumentSource(),
            recognizer: VisionTextRecognizer(),
            cache: nil
        )
        let result = try await processor.process(
            OCRRequest(
                sourceURL: fixtureURL,
                pageSelection: "1",
                settings: RecognitionSettings()
            )
        ) { _ in }
        var ocrContract = try dictionary(for: result)
        ocrContract["source_path"] = "<fixture>"
        ocrContract["source_sha256"] = "<sha256>"

        let imageOnlyResult = try await processor.process(
            OCRRequest(
                sourceURL: imageOnlyURL,
                pageSelection: "1",
                settings: RecognitionSettings()
            )
        ) { _ in }
        var imageOnlyContract = try dictionary(for: imageOnlyResult)
        imageOnlyContract["source_path"] = "<fixture>"
        imageOnlyContract["source_sha256"] = "<sha256>"

        let fixtures = [
            "inspect_mixed": inspectionContract,
            "ocr_existing_text": ocrContract,
            "ocr_image_only": imageOnlyContract,
        ]
        for (name, contract) in fixtures {
            let data = try stableJSONData(contract)
            try data.write(
                to: outputDirectory.appendingPathComponent("\(name).json"),
                options: .atomic
            )
            let expectedData = try Data(
                contentsOf: expectedDirectory.appendingPathComponent("\(name).json")
            )
            let expected = try dictionary(from: expectedData)
            if name == "inspect_mixed" {
                #expect(contract as NSDictionary == expected as NSDictionary)
            } else {
                try expectNormalizedOCRSchema(
                    contract,
                    matchesInvariantsIn: expected
                )
            }
        }

        let visionContractURL = outputDirectory
            .appendingPathComponent("ocr_image_only.json")
        #expect(FileManager.default.fileExists(atPath: visionContractURL.path))
        let visionContract = try dictionary(
            from: Data(contentsOf: visionContractURL)
        )
        let visionPages = try #require(
            visionContract["pages"] as? [[String: Any]]
        )
        let visionPage = try #require(visionPages.first)
        #expect(visionPage["method"] as? String == "vision_ocr")
        let visionLines = try #require(
            visionPage["lines"] as? [[String: Any]]
        )
        let visionLine = try #require(visionLines.first)
        #expect(visionLine["confidence"] is NSNumber)
    }
}

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func dictionary<Value: Encodable>(for value: Value) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func dictionary(from data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func expectNormalizedOCRSchema(
    _ contract: [String: Any],
    matchesInvariantsIn expected: [String: Any]
) throws {
    let topLevelFields: Set<String> = [
        "source_path",
        "source_sha256",
        "pages",
        "failed_pages",
        "empty_ocr_pages",
        "rotated_ocr_pages",
    ]
    #expect(Set(contract.keys) == topLevelFields)
    #expect(Set(expected.keys) == topLevelFields)
    #expect(contract["source_path"] as? String == "<fixture>")
    #expect(contract["source_sha256"] as? String == "<sha256>")
    #expect(
        contract["failed_pages"] as? NSArray
            == expected["failed_pages"] as? NSArray
    )
    #expect(
        contract["empty_ocr_pages"] as? NSArray
            == expected["empty_ocr_pages"] as? NSArray
    )
    #expect(contract["rotated_ocr_pages"] is [String: Any])

    let pages = try #require(contract["pages"] as? [[String: Any]])
    let expectedPages = try #require(expected["pages"] as? [[String: Any]])
    #expect(pages.count == expectedPages.count)
    for (page, expectedPage) in zip(pages, expectedPages) {
        let pageFields: Set<String> = [
            "page",
            "text",
            "method",
            "lines",
            "orientation",
        ]
        #expect(Set(page.keys) == pageFields)
        #expect(Set(expectedPage.keys) == pageFields)
        #expect(
            page["page"] as? NSNumber
                == expectedPage["page"] as? NSNumber
        )
        #expect(
            page["method"] as? String
                == expectedPage["method"] as? String
        )
        #expect(page["text"] is String)
        #expect(page["orientation"] is NSNumber)

        let lines = try #require(page["lines"] as? [[String: Any]])
        for line in lines {
            let lineFields: Set<String> = [
                "text",
                "confidence",
                "bounding_box",
            ]
            #expect(Set(line.keys) == lineFields)
            #expect(line["text"] is String)
            #expect(line["confidence"] is NSNumber)
            let boundingBox = try #require(
                line["bounding_box"] as? [String: Any]
            )
            #expect(
                Set(boundingBox.keys)
                    == Set(["x", "y", "width", "height"])
            )
            #expect(boundingBox.values.allSatisfy { $0 is NSNumber })
        }
    }
}

private func stableJSONData(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    return data
}

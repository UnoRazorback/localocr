import Foundation
import LocalOCRCore
import Testing

@Suite(.serialized) struct EngineIntegrationTests {
    @Test func exportsSwiftResultsInTheNormalizedPythonContractShape() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "mixed",
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

        let fixtures = [
            "inspect_mixed": inspectionContract,
            "ocr_existing_text": ocrContract,
        ]
        for (name, contract) in fixtures {
            let data = try stableJSONData(contract)
            try data.write(
                to: outputDirectory.appendingPathComponent("\(name).json"),
                options: .atomic
            )
            let expected = try Data(
                contentsOf: expectedDirectory.appendingPathComponent("\(name).json")
            )
            #expect(try JSONSerialization.jsonObject(with: data) as? NSDictionary
                == JSONSerialization.jsonObject(with: expected) as? NSDictionary)
        }
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

private func stableJSONData(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    return data
}

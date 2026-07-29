import Foundation
import LocalOCRMCP
import MCP
import Testing

@Test func decoderResolvesRelativePathAndAppliesPDFDefaults() throws {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/work/project"))

    let request = try decoder.decode(
        name: "ocr_pdf",
        arguments: ["file_path": "fixtures/input.pdf"]
    )

    guard case let .ocrPDF(decoded) = request else {
        Issue.record("Expected ocr_pdf request")
        return
    }
    #expect(decoded.fileURL.path == "/work/project/fixtures/input.pdf")
    #expect(decoded.pageRange == nil)
    #expect(decoded.dpi == 250)
    #expect(decoded.forceOCR == false)
    #expect(decoded.includeLines == false)
    #expect(decoded.usesCache == true)
}

@Test func decoderMapsEveryExplicitPDFAndBatchOption() throws {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    let request = try decoder.decode(
        name: "ocr_pdf_batch",
        arguments: [
            "file_paths": ["/one.pdf", "two.pdf"],
            "page_range": "2-4",
            "dpi": 300,
            "force_ocr": true,
            "include_lines": true,
        ]
    )

    guard case let .ocrPDFBatch(decoded) = request else {
        Issue.record("Expected ocr_pdf_batch request")
        return
    }
    #expect(decoded.fileURLs.map(\.path) == ["/one.pdf", "/cwd/two.pdf"])
    #expect(decoded.pageRange == "2-4")
    #expect(decoded.dpi == 300)
    #expect(decoded.forceOCR)
    #expect(decoded.includeLines)
    #expect(decoded.usesCache)
}

@Test func decoderResolvesOptionalSearchableOutputPath() throws {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    let request = try decoder.decode(
        name: "make_searchable_pdf",
        arguments: [
            "file_path": "input.pdf",
            "output_path": "out/output.pdf",
        ]
    )

    guard case let .makeSearchablePDF(decoded) = request else {
        Issue.record("Expected make_searchable_pdf request")
        return
    }
    #expect(decoded.fileURL.path == "/cwd/input.pdf")
    #expect(decoded.outputURL?.path == "/cwd/out/output.pdf")
    #expect(decoded.dpi == 250)
    #expect(decoded.forceOCR == false)
}

@Test func decoderRejectsUnknownArgumentsBeforeCallingAService() {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    #expect(throws: MCPArgumentError("unknown argument 'surprise'")) {
        try decoder.decode(
            name: "ocr_image",
            arguments: ["file_path": "/image.png", "surprise": true]
        )
    }
}

@Test func decoderRejectsMissingEmptyAndMismatchedPaths() {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    #expect(throws: MCPArgumentError("file_path is required")) {
        try decoder.decode(name: "inspect_pdf", arguments: [:])
    }
    #expect(throws: MCPArgumentError("file_path must be a non-empty string")) {
        try decoder.decode(name: "inspect_pdf", arguments: ["file_path": "  "])
    }
    #expect(throws: MCPArgumentError("file_path must be a non-empty string")) {
        try decoder.decode(name: "inspect_pdf", arguments: ["file_path": 42])
    }
    #expect(throws: MCPArgumentError("file_paths must be a non-empty array of non-empty strings")) {
        try decoder.decode(name: "ocr_pdf_batch", arguments: ["file_paths": []])
    }
    #expect(throws: MCPArgumentError("file_paths must be a non-empty array of non-empty strings")) {
        try decoder.decode(name: "ocr_pdf_batch", arguments: ["file_paths": ["/ok.pdf", 42]])
    }
}

@Test func decoderRejectsNonIntegralAndOutOfRangeDPI() {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))
    let expected = MCPArgumentError("dpi must be an integer from 72 through 600")

    #expect(throws: expected) {
        try decoder.decode(
            name: "ocr_pdf",
            arguments: ["file_path": "/input.pdf", "dpi": 249.5]
        )
    }
    #expect(throws: expected) {
        try decoder.decode(
            name: "ocr_pdf",
            arguments: ["file_path": "/input.pdf", "dpi": 71]
        )
    }
    #expect(throws: expected) {
        try decoder.decode(
            name: "ocr_pdf",
            arguments: ["file_path": "/input.pdf", "dpi": 601]
        )
    }
}

@Test func decoderAcceptsMathematicallyIntegralJSONNumbersForDPI() throws {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    let request = try decoder.decode(
        name: "ocr_pdf",
        arguments: ["file_path": "/input.pdf", "dpi": .double(300.0)]
    )

    guard case let .ocrPDF(decoded) = request else {
        Issue.record("Expected ocr_pdf request")
        return
    }
    #expect(decoded.dpi == 300)
}

@Test func decoderUsesDefaultsOnlyWhenKeysAreAbsent() {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))

    #expect(throws: MCPArgumentError("force_ocr must be a boolean")) {
        try decoder.decode(
            name: "ocr_pdf",
            arguments: ["file_path": "/input.pdf", "force_ocr": .null]
        )
    }
    #expect(throws: MCPArgumentError("page_range must be a string")) {
        try decoder.decode(
            name: "ocr_pdf",
            arguments: ["file_path": "/input.pdf", "page_range": .null]
        )
    }
}

@Test func decoderRejectsUnknownToolNames() {
    let decoder = MCPArgumentDecoder(currentDirectory: URL(fileURLWithPath: "/cwd"))
    #expect(throws: MCPArgumentError("unknown tool 'not_a_tool'")) {
        try decoder.decode(name: "not_a_tool", arguments: [:])
    }
}

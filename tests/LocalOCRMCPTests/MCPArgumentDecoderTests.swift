import Foundation
@testable import LocalOCRMCP
import MCP
import Testing

@Suite struct MCPArgumentDecoderTests {
    private let currentDirectory = URL(fileURLWithPath: "/tmp/localocr-working-directory", isDirectory: true)

    @Test func pdfArgumentsUseDefaultsAndResolveRelativePaths() throws {
        let request = try MCPArgumentDecoder(currentDirectory: currentDirectory).decode(
            toolName: "ocr_pdf",
            arguments: ["file_path": "invoices/july.pdf"]
        )

        guard case let .ocrPDF(value) = request else {
            Issue.record("Expected an ocr_pdf request")
            return
        }
        #expect(value.fileURL.path == "/tmp/localocr-working-directory/invoices/july.pdf")
        #expect(value.pageRange == nil)
        #expect(value.dpi == 250)
        #expect(value.forceOCR == false)
        #expect(value.includeLines == false)
    }

    @Test func decoderRejectsUnknownArgumentsAndInvalidDPI() throws {
        let decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)

        #expect(throws: MCPArgumentError.unknownArgument("unexpected")) {
            try decoder.decode(toolName: "ocr_image", arguments: ["file_path": "scan.png", "unexpected": true])
        }
        #expect(throws: MCPArgumentError.invalidDPI) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "dpi": 250.5])
        }
        #expect(throws: MCPArgumentError.invalidDPI) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "dpi": 601])
        }
    }

    @Test func decoderAcceptsDocumentedDPIBoundsAndRejectsEveryWrongArgumentType() throws {
        let decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)

        for dpi in [72, 600] {
            let request = try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "dpi": .int(dpi)])
            guard case let .ocrPDF(value) = request else {
                Issue.record("Expected an ocr_pdf request")
                return
            }
            #expect(value.dpi == dpi)
        }

        #expect(throws: MCPArgumentError.invalidPath("file_path")) {
            try decoder.decode(toolName: "ocr_image", arguments: ["file_path": 1])
        }
        #expect(throws: MCPArgumentError.invalidPath("file_path")) {
            try decoder.decode(toolName: "ocr_image", arguments: ["file_path": "   "])
        }
        #expect(throws: MCPArgumentError.invalidPageRange) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "page_range": 1])
        }
        #expect(throws: MCPArgumentError.invalidBoolean("force_ocr")) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "force_ocr": "true"])
        }
        #expect(throws: MCPArgumentError.invalidBoolean("include_lines")) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "include_lines": 1])
        }
        #expect(throws: MCPArgumentError.invalidDPI) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "dpi": "250"])
        }
        #expect(throws: MCPArgumentError.invalidDPI) {
            try decoder.decode(toolName: "ocr_pdf", arguments: ["file_path": "scan.pdf", "dpi": 71])
        }
        #expect(throws: MCPArgumentError.invalidPath("file_paths")) {
            try decoder.decode(toolName: "ocr_pdf_batch", arguments: ["file_paths": "scan.pdf"])
        }
    }

    @Test func batchRequiresNonemptyStringPathsAndSearchableAllowsAnOptionalOutputPath() throws {
        let decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)

        #expect(throws: MCPArgumentError.emptyBatch) {
            try decoder.decode(toolName: "ocr_pdf_batch", arguments: ["file_paths": []])
        }
        #expect(throws: MCPArgumentError.invalidPath("file_paths")) {
            try decoder.decode(toolName: "ocr_pdf_batch", arguments: ["file_paths": ["ok.pdf", 9]])
        }

        let request = try decoder.decode(
            toolName: "make_searchable_pdf",
            arguments: ["file_path": "/input.pdf", "output_path": "output.pdf", "force_ocr": true, "dpi": 300]
        )
        guard case let .makeSearchablePDF(value) = request else {
            Issue.record("Expected a make_searchable_pdf request")
            return
        }
        #expect(value.fileURL.path == "/input.pdf")
        #expect(value.outputURL?.path == "/tmp/localocr-working-directory/output.pdf")
        #expect(value.dpi == 300)
        #expect(value.forceOCR == true)
    }

    @Test func intelligenceToolsResolvePathsLexicallyWithoutRequiringFilesToExist() throws {
        let decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)

        let summary = try decoder.decode(
            toolName: "summarize_document",
            arguments: ["file_path": "missing/summary.pdf"]
        )
        let organization = try decoder.decode(
            toolName: "organize_document",
            arguments: ["file_path": "missing/organization.png"]
        )
        let extraction = try decoder.decode(
            toolName: "extract_document_fields",
            arguments: ["file_path": "missing/form.pdf", "fields": [" date ", "total"]]
        )

        guard case let .summarizeDocument(summaryRequest) = summary else {
            Issue.record("Expected a summarize_document request")
            return
        }
        guard case let .organizeDocument(organizationRequest) = organization else {
            Issue.record("Expected an organize_document request")
            return
        }
        guard case let .extractDocumentFields(extractionRequest) = extraction else {
            Issue.record("Expected an extract_document_fields request")
            return
        }
        #expect(summaryRequest.fileURL.path == "/tmp/localocr-working-directory/missing/summary.pdf")
        #expect(organizationRequest.fileURL.path == "/tmp/localocr-working-directory/missing/organization.png")
        #expect(extractionRequest.fileURL.path == "/tmp/localocr-working-directory/missing/form.pdf")
        #expect(extractionRequest.fields == ["date", "total"])
    }

    @Test func extractionRequiresOneThroughThirtyTwoUniqueTrimmedBoundedFieldNames() throws {
        let decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)
        let thirtyOneNames = (1 ... 31).map { "field_\($0)" }
        let oneHundredTwentyEightCharacters = String(repeating: "x", count: 128)
        let oneHundredTwentyEightGraphemes = String(repeating: "👨🏽‍💻", count: 128)

        let request = try decoder.decode(
            toolName: "extract_document_fields",
            arguments: [
                "file_path": "form.pdf",
                "fields": .array(thirtyOneNames.map(Value.string) + [.string(oneHundredTwentyEightCharacters)])
            ]
        )
        guard case let .extractDocumentFields(value) = request else {
            Issue.record("Expected an extract_document_fields request")
            return
        }
        #expect(value.fields.count == 32)

        let graphemeRequest = try decoder.decode(
            toolName: "extract_document_fields",
            arguments: ["file_path": "form.pdf", "fields": .array([.string(oneHundredTwentyEightGraphemes)])]
        )
        guard case let .extractDocumentFields(graphemeValue) = graphemeRequest else {
            Issue.record("Expected an extract_document_fields request")
            return
        }
        #expect(graphemeValue.fields == [oneHundredTwentyEightGraphemes])

        let invalidFields: [Value] = [
            .string("not-an-array"),
            .array([]),
            .array((1 ... 33).map { .string("field_\($0)") }),
            .array([.string("date"), .int(1)]),
            .array([.string("   ")]),
            .array([.string(String(repeating: "x", count: 129))]),
            .array([.string(String(repeating: "👨🏽‍💻", count: 129))]),
            .array([.string("date"), .string(" date ")]),
        ]

        #expect(throws: MCPArgumentError.missingArgument("fields")) {
            try decoder.decode(
                toolName: "extract_document_fields",
                arguments: ["file_path": "form.pdf"]
            )
        }
        for fields in invalidFields {
            #expect(throws: MCPArgumentError.invalidFields) {
                try decoder.decode(
                    toolName: "extract_document_fields",
                    arguments: ["file_path": "form.pdf", "fields": fields]
                )
            }
        }
    }
}

import Foundation
@testable import LocalOCRMCP
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
}

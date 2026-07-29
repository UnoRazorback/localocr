import Foundation
@testable import LocalOCRMCP
import Testing

@Suite struct MCPToolCatalogTests {
    @Test func catalogHasTheExactLegacyToolNamesAndContractSnapshot() throws {
        let tools = MCPToolCatalog.tools.sorted { $0.name < $1.name }

        #expect(tools.map(\.name) == [
            "get_pdf_page_count",
            "inspect_pdf",
            "make_searchable_pdf",
            "ocr_image",
            "ocr_pdf",
            "ocr_pdf_batch"
        ])

        var actual = try JSONEncoder.sorted.encode(tools)
        actual.append(0x0A)
        let expected = try Data(contentsOf: contractURL(named: "mcp_tool_catalog"))
        #expect(actual == expected)
    }

    @Test func catalogEnforcesStrictLocalPathAndDPIContracts() {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools.map { ($0.name, $0) })
        let pdfSchema = tools["ocr_pdf"]?.inputSchema.objectValue
        let batchSchema = tools["ocr_pdf_batch"]?.inputSchema.objectValue

        #expect(pdfSchema?["additionalProperties"] == .bool(false))
        #expect(pdfSchema?["required"] == .array([.string("file_path")]))
        #expect(pdfSchema?["properties"]?.objectValue?["dpi"]?.objectValue?["minimum"] == .int(72))
        #expect(pdfSchema?["properties"]?.objectValue?["dpi"]?.objectValue?["maximum"] == .int(600))
        #expect(batchSchema?["properties"]?.objectValue?["file_paths"]?.objectValue?["minItems"] == .int(1))
        #expect(tools["get_pdf_page_count"]?.outputSchema == nil)
        #expect(tools["ocr_image"]?.outputSchema == nil)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private func contractURL(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contract/expected/\(name).json")
}

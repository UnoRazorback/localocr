import Foundation
@testable import LocalOCRMCP
import Testing

@Suite struct MCPToolCatalogTests {
    @Test func catalogHasTheExactNineToolNamesAndContractSnapshot() throws {
        let tools = MCPToolCatalog.tools.sorted { $0.name < $1.name }

        #expect(tools.map(\.name) == [
            "extract_document_fields",
            "get_pdf_page_count",
            "inspect_pdf",
            "make_searchable_pdf",
            "ocr_image",
            "ocr_pdf",
            "ocr_pdf_batch",
            "organize_document",
            "summarize_document"
        ])

        var actual = try JSONEncoder.sorted.encode(tools)
        actual.append(0x0A)
        let expected = try Data(contentsOf: contractURL(named: "mcp_tool_catalog"))
        #expect(actual == expected)
    }

    @Test func catalogEnforcesStrictLocalPathAndDPIContracts() {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools.map { ($0.name, $0) })
        let pdfSchema = tools["ocr_pdf"]?.inputSchema.objectValue
        let batchInputSchema = tools["ocr_pdf_batch"]?.inputSchema.objectValue
        let batchSchema = tools["ocr_pdf_batch"]?.outputSchema?.objectValue
        let resultsSchema = batchSchema?["properties"]?.objectValue?["results"]
        let batchItems = resultsSchema?.objectValue?["items"]
        let batchAlternatives = batchItems?.objectValue?["oneOf"]?.arrayValue

        #expect(pdfSchema?["additionalProperties"] == .bool(false))
        #expect(pdfSchema?["required"] == .array([.string("file_path")]))
        #expect(pdfSchema?["properties"]?.objectValue?["dpi"]?.objectValue?["minimum"] == .int(72))
        #expect(pdfSchema?["properties"]?.objectValue?["dpi"]?.objectValue?["maximum"] == .int(600))
        #expect(batchInputSchema?["properties"]?.objectValue?["file_paths"]?.objectValue?["minItems"] == .int(1))
        #expect(batchAlternatives?.count == 2)
        #expect(batchAlternatives?[0].objectValue?["additionalProperties"] == .bool(false))
        #expect(batchAlternatives?[0].objectValue?["required"] == .array([
            .string("status"), .string("source_path"), .string("source_sha256"), .string("pages"),
            .string("failed_pages"), .string("empty_ocr_pages"), .string("rotated_ocr_pages")
        ]))
        #expect(batchAlternatives?[1].objectValue?["additionalProperties"] == .bool(false))
        #expect(batchAlternatives?[1].objectValue?["required"] == .array([
            .string("source_path"), .string("status"), .string("error")
        ]))
        #expect(tools["get_pdf_page_count"]?.outputSchema == nil)
        #expect(tools["ocr_image"]?.outputSchema == nil)
    }

    @Test func intelligenceSchemasArePurposeLimitedBoundedStructuredAndReadOnly() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools.map { ($0.name, $0) })

        for name in ["summarize_document", "organize_document"] {
            let tool = try #require(tools[name])
            let schema = try #require(tool.inputSchema.objectValue)
            let properties = try #require(schema["properties"]?.objectValue)
            #expect(Set(properties.keys) == ["file_path"])
            #expect(schema["required"] == .array([.string("file_path")]))
            #expect(schema["additionalProperties"] == .bool(false))
            #expect(tool.annotations.readOnlyHint == true)
            #expect(tool.annotations.idempotentHint == true)
            #expect(tool.annotations.destructiveHint == false)
            #expect(tool.annotations.openWorldHint == false)
            #expect(tool.outputSchema != nil)
        }

        let extraction = try #require(tools["extract_document_fields"])
        let extractionInput = try #require(extraction.inputSchema.objectValue)
        let extractionProperties = try #require(extractionInput["properties"]?.objectValue)
        let fields = try #require(extractionProperties["fields"]?.objectValue)
        #expect(Set(extractionProperties.keys) == ["file_path", "fields"])
        #expect(extractionInput["required"] == .array([.string("file_path"), .string("fields")]))
        #expect(fields["type"] == .string("array"))
        #expect(fields["minItems"] == .int(1))
        #expect(fields["maxItems"] == .int(32))
        #expect(fields["uniqueItems"] == .bool(true))
        #expect(fields["items"]?.objectValue?["type"] == .string("string"))
        #expect(fields["items"]?.objectValue?["minLength"] == .int(1))
        #expect(fields["items"]?.objectValue?["maxLength"] == .int(128))
        #expect(extraction.annotations.readOnlyHint == true)
        #expect(extraction.annotations.openWorldHint == false)

        let extractionOutput = try #require(extraction.outputSchema?.objectValue)
        let extractionOutputProperties = try #require(extractionOutput["properties"]?.objectValue)
        let outputItems = try #require(extractionOutputProperties["fields"]?.objectValue?["items"]?.objectValue)
        let outputProperties = try #require(outputItems["properties"]?.objectValue)
        #expect(extractionOutput["type"] == .string("object"))
        #expect(extractionOutput["additionalProperties"] == .bool(false))
        #expect(extractionOutput["required"] == .array([.string("fields")]))
        #expect(outputItems["required"] == .array([
            .string("name"), .string("value"), .string("source_page"), .string("evidence")
        ]))
        #expect(outputProperties["value"]?.objectValue?["anyOf"]?.arrayValue == [
            .object(["type": "string"]), .object(["type": "null"])
        ])
        #expect(outputProperties["source_page"]?.objectValue?["anyOf"]?.arrayValue == [
            .object(["type": "integer"]), .object(["type": "null"])
        ])
        #expect(outputProperties["evidence"]?.objectValue?["anyOf"]?.arrayValue == [
            .object(["type": "string"]), .object(["type": "null"])
        ])
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

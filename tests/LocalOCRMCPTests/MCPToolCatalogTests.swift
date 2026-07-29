import Foundation
import LocalOCRMCP
import MCP
import Testing

@Test func toolCatalogMatchesLegacyNamesAndSnapshot() throws {
    let tools = MCPToolCatalog.tools.sorted { $0.name < $1.name }

    #expect(tools.map(\.name) == [
        "get_pdf_page_count",
        "inspect_pdf",
        "make_searchable_pdf",
        "ocr_image",
        "ocr_pdf",
        "ocr_pdf_batch",
    ])

    let actual = try canonicalJSON(tools)
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contract/expected/mcp_tool_catalog.json")
    let expected = try Data(contentsOf: fixtureURL)
    #expect(String(decoding: actual, as: UTF8.self) == String(decoding: expected, as: UTF8.self))
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

import Foundation
@testable import LocalOCRIntelligence
import Testing

@Suite struct IntelligenceModelsTests {
    @Test func documentOrdersPagesAndDropsWhitespaceOnlyText() {
        let document = IntelligenceDocument(pages: [
            .init(number: 2, text: " Total: $19.00 "),
            .init(number: 1, text: "   "),
        ])
        #expect(document.pages.map(\.number) == [2])
    }

    @Test func resultModelsEncodeNullForAbsentFields() throws {
        let field = ExtractedDocumentField(name: "date", value: nil, sourcePage: nil, evidence: nil)
        let data = try JSONEncoder().encode(field)
        #expect(String(decoding: data, as: UTF8.self).contains("\"value\":null"))
    }
}

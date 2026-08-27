@testable import LocalOCRIntelligence
import Testing

@Suite struct IntelligenceChunkerTests {
    @Test func chunksKeepWholePagesAndTheirOriginalAttributionWhenTheyFit() {
        let document = IntelligenceDocument(pages: [
            .init(number: 2, text: "second page"),
            .init(number: 1, text: "first page")
        ])

        let chunks = IntelligenceChunker.chunks(document: document, characterBudget: 11)

        #expect(chunks == [
            .init(page: 1, text: "first page"),
            .init(page: 2, text: "second page")
        ])
    }

    @Test func chunksSplitOversizedPagesAtWordBoundariesWithoutDroppingText() {
        let document = IntelligenceDocument(pages: [.init(number: 4, text: "alpha beta gamma")])

        let chunks = IntelligenceChunker.chunks(document: document, characterBudget: 10)

        #expect(chunks == [
            .init(page: 4, text: "alpha beta"),
            .init(page: 4, text: " gamma")
        ])
        #expect(chunks.allSatisfy { $0.text.count <= 10 })
        #expect(chunks.map(\.text).joined() == "alpha beta gamma")
    }

    @Test func chunksPreserveParagraphDelimitersWhenSplitting() {
        let document = IntelligenceDocument(pages: [.init(number: 5, text: "alpha\n\nbeta gamma")])

        let chunks = IntelligenceChunker.chunks(document: document, characterBudget: 10)

        #expect(chunks.allSatisfy { $0.page == 5 && $0.text.count <= 10 })
        #expect(chunks.map(\.text).joined() == "alpha\n\nbeta gamma")
    }

    @Test func chunksPreserveStablePageAndFragmentOrderAcrossPageBoundaries() {
        let document = IntelligenceDocument(pages: [
            .init(number: 3, text: "one two three"),
            .init(number: 1, text: "four five")
        ])

        let chunks = IntelligenceChunker.chunks(document: document, characterBudget: 9)

        #expect(chunks.map(\.page) == [1, 3, 3])
        #expect(chunks.map(\.text).joined() == "four fiveone two three")
        #expect(chunks[1...].map(\.text).joined() == "one two three")
    }
}

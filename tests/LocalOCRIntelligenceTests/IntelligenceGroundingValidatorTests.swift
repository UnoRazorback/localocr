@testable import LocalOCRIntelligence
import Testing

@Suite struct IntelligenceGroundingValidatorTests {
    @Test func validatorDropsCitationNotFoundOnClaimedPage() {
        let document = IntelligenceDocument(pages: [.init(number: 1, text: "Invoice total $42.00")])

        let citations = IntelligenceGroundingValidator.validCitations(
            [.init(page: 1, quote: "Total $99.00")], in: document
        )

        #expect(citations.isEmpty)
    }

    @Test func validatorMatchesCaseAndUnicodeWhitespaceWhileKeepingOriginalQuote() {
        let document = IntelligenceDocument(pages: [.init(number: 1, text: "Invoice\u{00A0}Total\n$42.00")])
        let citation = IntelligenceCitation(page: 1, quote: "invoice total $42.00")

        let citations = IntelligenceGroundingValidator.validCitations([citation], in: document)

        #expect(citations == [citation])
    }

    @Test func validatorClearsAllOptionalExtractionDataWhenEvidenceIsNotOnClaimedPage() {
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Invoice total $42.00"),
            .init(number: 2, text: "Account name: Acme Corp")
        ])
        let field = ExtractedDocumentField(
            name: "accountName",
            value: "Acme Corp",
            sourcePage: 1,
            evidence: "Account name: Acme Corp"
        )

        let fields = IntelligenceGroundingValidator.validExtractedFields([field], in: document)

        #expect(fields == [.init(name: "accountName", value: nil, sourcePage: nil, evidence: nil)])
    }

    @Test func validatorClearsAllOptionalExtractionDataWhenValueIsNotOnClaimedPage() {
        let document = IntelligenceDocument(pages: [.init(number: 1, text: "Invoice total $42.00")])
        let field = ExtractedDocumentField(
            name: "total",
            value: "$99.00",
            sourcePage: 1,
            evidence: "Invoice total $42.00"
        )

        let fields = IntelligenceGroundingValidator.validExtractedFields([field], in: document)

        #expect(fields == [.init(name: "total", value: nil, sourcePage: nil, evidence: nil)])
    }

    @Test func validatorKeepsExtractionWhenValueAndEvidenceBothOccurOnClaimedPage() {
        let document = IntelligenceDocument(pages: [.init(number: 2, text: "Account Name: Acme Corp")])
        let field = ExtractedDocumentField(
            name: "accountName",
            value: "acme corp",
            sourcePage: 2,
            evidence: "account   name:\u{00A0}acme corp"
        )

        let fields = IntelligenceGroundingValidator.validExtractedFields([field], in: document)

        #expect(fields == [field])
    }
}

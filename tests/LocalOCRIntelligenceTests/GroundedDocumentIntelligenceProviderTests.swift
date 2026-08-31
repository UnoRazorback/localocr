@testable import LocalOCRIntelligence
import LocalOCRModelCore
import Testing

@Suite struct GroundedDocumentIntelligenceProviderTests {
    @Test func summaryDropsUngroundedItemsAndReturnsTheExactOperationProvenance() async throws {
        let provenance = LocalModelProvenance(
            provider: .ollama,
            providerDisplayName: "Ollama",
            model: "gemma4:8b",
            processing: .onDeviceLoopback,
            fingerprint: "sha256:abc",
            qualifiedAt: nil
        )
        let driver = ClosureStructuredIntelligenceSessionDriver(
            summarize: { prompt in
                if prompt.contains("page number=\"1\"") {
                    return .init(items: [
                        .init(text: "Alpha is present.", page: 1, evidence: "Alpha fact"),
                        .init(text: "Invented detail.", page: 1, evidence: "Not in OCR")
                    ])
                }
                return .init(items: [
                    .init(text: "Beta is present.", page: 2, evidence: "Beta fact")
                ])
            }
        )
        let provider = GroundedDocumentIntelligenceProvider(
            availability: { .available },
            provenance: provenance,
            sessionDriver: driver
        )

        let result = try await provider.summarize(Self.document)

        #expect(result.model == provenance)
        #expect(result.value == .init(
            text: "Alpha is present.\n\nBeta is present.",
            citations: [
                .init(page: 1, quote: "Alpha fact"),
                .init(page: 2, quote: "Beta fact")
            ]
        ))
    }

    @Test func organizationKeepsOnlyGroundedComponentsAndReturnsExactProvenance() async throws {
        let provenance = Self.externalProvenance
        let driver = ClosureStructuredIntelligenceSessionDriver(
            organize: { prompt in
                if prompt.contains("page number=\"1\"") {
                    return .init(
                        title: .init(value: "Alpha", page: 1, evidence: "Alpha fact"),
                        category: .init(value: "Facts", page: 1, evidence: "Alpha fact"),
                        tags: [
                            .init(value: "alpha", page: 1, evidence: "Alpha fact"),
                            .init(value: "invented", page: 1, evidence: "Not in OCR")
                        ]
                    )
                }
                return .init(
                    title: .init(value: "Beta", page: 2, evidence: "Beta fact"),
                    category: .init(value: "Other", page: 2, evidence: "Beta fact"),
                    tags: [.init(value: "beta", page: 2, evidence: "Beta fact")]
                )
            }
        )
        let provider = GroundedDocumentIntelligenceProvider(
            availability: { .available },
            provenance: provenance,
            sessionDriver: driver
        )

        let result = try await provider.organize(Self.document)

        #expect(result.model == provenance)
        #expect(result.value == .init(
            title: "Alpha",
            category: "Facts",
            tags: ["alpha", "beta"],
            citations: [
                .init(page: 1, quote: "Alpha fact"),
                .init(page: 2, quote: "Beta fact")
            ]
        ))
    }

    @Test func extractionPreservesRequestedOrderNullsUngroundedValuesAndReturnsExactProvenance() async throws {
        let provenance = Self.externalProvenance
        let driver = ClosureStructuredIntelligenceSessionDriver(
            extract: { _, _ in
                .init(fields: [
                    .init(name: "date", value: "2026-08-27", page: 1, evidence: "Date: 2026-08-27"),
                    .init(name: "total", value: "$99.00", page: 1, evidence: "Total: $42.00"),
                    .init(name: "unrequested", value: "Alpha", page: 1, evidence: "Alpha fact")
                ])
            }
        )
        let provider = GroundedDocumentIntelligenceProvider(
            availability: { .available },
            provenance: provenance,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Date: 2026-08-27\nTotal: $42.00\nAlpha fact")
        ])

        let result = try await provider.extract(["total", "date", "missing"], from: document)

        #expect(result.model == provenance)
        #expect(result.value == [
            .init(name: "total", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "date", value: "2026-08-27", sourcePage: 1, evidence: "Date: 2026-08-27"),
            .init(name: "missing", value: nil, sourcePage: nil, evidence: nil)
        ])
    }

    private static let document = IntelligenceDocument(pages: [
        .init(number: 2, text: "Beta fact"),
        .init(number: 1, text: "Alpha fact")
    ])

    private static let externalProvenance = LocalModelProvenance(
        provider: .ollama,
        providerDisplayName: "Ollama",
        model: "gemma4:8b",
        processing: .onDeviceLoopback,
        fingerprint: "sha256:abc",
        qualifiedAt: nil
    )
}

private struct ClosureStructuredIntelligenceSessionDriver: StructuredIntelligenceSessionDriving {
    let contextSize: Int
    private let summarizeClosure: @Sendable (String) async throws -> GeneratedSummary
    private let organizeClosure: @Sendable (String) async throws -> GeneratedOrganization
    private let extractClosure: @Sendable ([String], String) async throws -> GeneratedExtraction

    init(
        contextSize: Int = 4_096,
        summarize: @escaping @Sendable (String) async throws -> GeneratedSummary = { _ in .init(items: []) },
        organize: @escaping @Sendable (String) async throws -> GeneratedOrganization = { _ in .init(title: nil, category: nil, tags: []) },
        extract: @escaping @Sendable ([String], String) async throws -> GeneratedExtraction = { _, _ in .init(fields: []) }
    ) {
        self.contextSize = contextSize
        self.summarizeClosure = summarize
        self.organizeClosure = organize
        self.extractClosure = extract
    }

    func summarize(prompt: String) async throws -> GeneratedSummary {
        try await summarizeClosure(prompt)
    }

    func organize(prompt: String) async throws -> GeneratedOrganization {
        try await organizeClosure(prompt)
    }

    func extract(names: [String], prompt: String) async throws -> GeneratedExtraction {
        try await extractClosure(names, prompt)
    }
}

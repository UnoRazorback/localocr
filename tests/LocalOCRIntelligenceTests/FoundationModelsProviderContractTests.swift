import Foundation
@testable import LocalOCRIntelligence
import Testing

#if canImport(FoundationModels)
import FoundationModels

@Suite struct FoundationModelsProviderContractTests {
    @Test func mapsAllSystemModelAvailabilityReasonsWithoutUsingTheModel() {
        guard #available(macOS 26.0, *) else { return }

        #expect(FoundationModelsIntelligenceProvider.mappedAvailability(
            .unavailable(.deviceNotEligible), supportsCurrentLocale: true
        ) == .deviceNotEligible)
        #expect(FoundationModelsIntelligenceProvider.mappedAvailability(
            .unavailable(.appleIntelligenceNotEnabled), supportsCurrentLocale: true
        ) == .appleIntelligenceNotEnabled)
        #expect(FoundationModelsIntelligenceProvider.mappedAvailability(
            .unavailable(.modelNotReady), supportsCurrentLocale: true
        ) == .modelNotReady)
    }

    @Test func mapsUnsupportedCurrentLocaleBeforeStartingASession() {
        guard #available(macOS 26.0, *) else { return }

        #expect(FoundationModelsIntelligenceProvider.mappedAvailability(
            .available, supportsCurrentLocale: false
        ) == .unsupportedLanguage)
        #expect(FoundationModelsIntelligenceProvider.mappedAvailability(
            .available, supportsCurrentLocale: true
        ) == .available)
    }

    @Test func unavailableProviderReportsAndThrowsItsReason() async {
        let provider = UnavailableIntelligenceProvider(.requiresMacOS26)

        #expect(provider.availability == .requiresMacOS26)
        await #expect(throws: IntelligenceError.unavailable(.requiresMacOS26)) {
            try await provider.summarize(Self.document)
        }
    }

    @Test func summarizeAggregatesChunksInPageOrderAndDropsUngroundedItems() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
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
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 1_800,
            sessionDriver: driver
        )

        let result = try await provider.summarize(Self.document)

        #expect(result == .init(
            text: "Alpha is present.\n\nBeta is present.",
            citations: [
                .init(page: 1, quote: "Alpha fact"),
                .init(page: 2, quote: "Beta fact")
            ]
        ))
    }

    @Test func organizeAggregatesGroundedComponentsAndRemovesUngroundedTags() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
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
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 1_800,
            sessionDriver: driver
        )

        let result = try await provider.organize(Self.document)

        #expect(result == .init(
            title: "Alpha",
            category: "Facts",
            tags: ["alpha", "beta"],
            citations: [
                .init(page: 1, quote: "Alpha fact"),
                .init(page: 2, quote: "Beta fact")
            ]
        ))
    }

    @Test func extractionReturnsEveryRequestedNameOnceInInputOrderAndNullsUngroundedValues() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            extract: { _, _ in
                .init(fields: [
                    .init(name: "date", value: "2026-08-27", page: 1, evidence: "Date: 2026-08-27"),
                    .init(name: "total", value: "$99.00", page: 1, evidence: "Total: $42.00"),
                    .init(name: "unrequested", value: "Alpha", page: 1, evidence: "Alpha fact")
                ])
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Date: 2026-08-27\nTotal: $42.00\nAlpha fact")
        ])

        let result = try await provider.extract(["total", "date", "missing"], from: document)

        #expect(result == [
            .init(name: "total", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "date", value: "2026-08-27", sourcePage: 1, evidence: "Date: 2026-08-27"),
            .init(name: "missing", value: nil, sourcePage: nil, evidence: nil)
        ])
    }

    @Test func extractionPromptCarriesRequestedFieldNamesOutsideTheOCRText() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            extract: { _, prompt in
                guard
                    prompt.contains("Requested field names"),
                    prompt.contains("1. invoiceDate"),
                    prompt.contains("2. total")
                else {
                    return .init(fields: [])
                }
                return .init(fields: [
                    .init(
                        name: "invoiceDate",
                        value: "2026-08-27",
                        page: 1,
                        evidence: "Date: 2026-08-27"
                    )
                ])
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Date: 2026-08-27\nTotal: $42.00")
        ])

        let result = try await provider.extract(["invoiceDate", "total"], from: document)

        #expect(result.first == .init(
            name: "invoiceDate",
            value: "2026-08-27",
            sourcePage: 1,
            evidence: "Date: 2026-08-27"
        ))
    }

    @Test func unavailableStatusPreventsGeneration() async {
        guard #available(macOS 26.0, *) else { return }

        let provider = FoundationModelsIntelligenceProvider(
            availability: { .modelNotReady },
            contextSize: 4_096,
            sessionDriver: ClosureFoundationModelsSessionDriver()
        )

        #expect(await provider.availability == .modelNotReady)
        await #expect(throws: IntelligenceError.unavailable(.modelNotReady)) {
            try await provider.summarize(Self.document)
        }
    }

    @Test func cancellationIsMappedToThePublicContract() async {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            summarize: { _ in throw CancellationError() }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )

        await #expect(throws: IntelligenceError.cancelled) {
            try await provider.summarize(Self.document)
        }
    }

    @Test func aContextOverflowSplitsAndRetriesOnlyTheOverflowingChunk() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = OverflowOnceSessionDriver()
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "alpha beta gamma")
        ])

        let result = try await provider.summarize(document)

        #expect(result.text == "First half.\n\nSecond half.")
        #expect(await driver.callCount == 3)
    }

    @Test(
        "Opt-in live Foundation Models smoke",
        .enabled(if: ProcessInfo.processInfo.environment["LOCALOCR_RUN_FOUNDATION_MODELS_TESTS"] == "1")
    )
    func optInLiveFoundationModelsSmokeUsesOnlySyntheticText() async throws {
        guard #available(macOS 26.0, *) else { return }

        let provider = FoundationModelsIntelligenceProvider()
        let availability = await provider.availability
        try #require(availability == .available, "Foundation Models unavailable: \(availability)")

        let result = try await provider.extract(
            ["total"],
            from: IntelligenceDocument(pages: [
                .init(number: 1, text: "Synthetic invoice total: $42.00")
            ])
        )

        #expect(result.count == 1)
        #expect(result.first?.name == "total")
        #expect(result.first?.value == "$42.00")
        #expect(result.first?.sourcePage == 1)
        #expect(result.first?.evidence != nil)
    }

    private static let document = IntelligenceDocument(pages: [
        .init(number: 2, text: "Beta fact"),
        .init(number: 1, text: "Alpha fact")
    ])
}

@available(macOS 26.0, *)
private struct ClosureFoundationModelsSessionDriver: FoundationModelsSessionDriving {
    private let summarizeClosure: @Sendable (String) async throws -> FoundationModelsGeneratedSummary
    private let organizeClosure: @Sendable (String) async throws -> FoundationModelsGeneratedOrganization
    private let extractClosure: @Sendable ([String], String) async throws -> FoundationModelsGeneratedExtraction

    init(
        summarize: @escaping @Sendable (String) async throws -> FoundationModelsGeneratedSummary = { _ in .init(items: []) },
        organize: @escaping @Sendable (String) async throws -> FoundationModelsGeneratedOrganization = { _ in .init(title: nil, category: nil, tags: []) },
        extract: @escaping @Sendable ([String], String) async throws -> FoundationModelsGeneratedExtraction = { _, _ in .init(fields: []) }
    ) {
        self.summarizeClosure = summarize
        self.organizeClosure = organize
        self.extractClosure = extract
    }

    func summarize(prompt: String) async throws -> FoundationModelsGeneratedSummary {
        try await summarizeClosure(prompt)
    }

    func organize(prompt: String) async throws -> FoundationModelsGeneratedOrganization {
        try await organizeClosure(prompt)
    }

    func extract(names: [String], prompt: String) async throws -> FoundationModelsGeneratedExtraction {
        try await extractClosure(names, prompt)
    }
}

@available(macOS 26.0, *)
private actor OverflowOnceSessionDriver: FoundationModelsSessionDriving {
    private(set) var callCount = 0

    func summarize(prompt: String) async throws -> FoundationModelsGeneratedSummary {
        callCount += 1
        if callCount == 1 {
            throw IntelligenceError.contextOverflow
        }
        if callCount == 2 {
            return .init(items: [
                .init(text: "First half.", page: 1, evidence: "alpha be")
            ])
        }
        return .init(items: [
            .init(text: "Second half.", page: 1, evidence: "ta gamma")
        ])
    }

    func organize(prompt: String) async throws -> FoundationModelsGeneratedOrganization {
        .init(title: nil, category: nil, tags: [])
    }

    func extract(names: [String], prompt: String) async throws -> FoundationModelsGeneratedExtraction {
        .init(fields: [])
    }
}
#endif

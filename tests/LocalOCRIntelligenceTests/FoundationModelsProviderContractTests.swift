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
            contextSize: 4_096,
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
            contextSize: 4_096,
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

    @Test func summaryAggregationStopsAtTwelveGroundedItemsAcrossChunks() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            summarize: { prompt in
                let page = prompt.contains("page number=\"1\"") ? 1 : 2
                let evidence = page == 1 ? "Alpha fact" : "Beta fact"
                return .init(items: (1...8).map { item in
                    .init(text: "Page \(page) item \(item).", page: page, evidence: evidence)
                })
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )

        let result = try await provider.summarize(Self.document)
        let statements = result.text.components(separatedBy: "\n\n")

        #expect(statements.count == 12)
        #expect(statements.first == "Page 1 item 1.")
        #expect(statements.last == "Page 2 item 4.")
    }

    @Test func organizationAggregationStopsAtFiveUniqueGroundedTagsAcrossChunks() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            organize: { prompt in
                let page = prompt.contains("page number=\"1\"") ? 1 : 2
                let evidence = page == 1 ? "Alpha fact" : "Beta fact"
                return .init(
                    title: .init(value: "Document", page: page, evidence: evidence),
                    category: .init(value: "Facts", page: page, evidence: evidence),
                    tags: (1...4).map { tag in
                        .init(value: "p\(page)-\(tag)", page: page, evidence: evidence)
                    }
                )
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )

        let result = try await provider.organize(Self.document)

        #expect(result.tags == ["p1-1", "p1-2", "p1-3", "p1-4", "p2-1"])
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

    @Test func extractionTrimsAndDeduplicatesRequestedNamesByFirstOccurrence() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = ClosureFoundationModelsSessionDriver(
            extract: { names, prompt in
                guard
                    names == ["total", "date"],
                    prompt.components(separatedBy: "1. total").count == 2,
                    prompt.components(separatedBy: "2. date").count == 2
                else {
                    return .init(fields: [])
                }
                return .init(fields: [
                    .init(name: "total", value: "$42.00", page: 1, evidence: "Total: $42.00"),
                    .init(name: "date", value: "2026-08-27", page: 1, evidence: "Date: 2026-08-27")
                ])
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Total: $42.00\nDate: 2026-08-27")
        ])

        let result = try await provider.extract(
            [" total ", "total", " date ", "date"],
            from: document
        )

        #expect(result == [
            .init(name: "total", value: "$42.00", sourcePage: 1, evidence: "Total: $42.00"),
            .init(name: "date", value: "2026-08-27", sourcePage: 1, evidence: "Date: 2026-08-27")
        ])
    }

    @Test(arguments: [[], [" ", "\n"]])
    func extractionRejectsEmptyOrAllWhitespaceRequests(names: [String]) async {
        guard #available(macOS 26.0, *) else { return }

        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: ClosureFoundationModelsSessionDriver()
        )

        await #expect(throws: IntelligenceError.invalidFields) {
            try await provider.extract(names, from: Self.document)
        }
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

    @Test func cancellationAfterNonCooperativeDriverSuccessExposesNoAggregate() async {
        guard #available(macOS 26.0, *) else { return }

        let driver = SuspendedSuccessSessionDriver()
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: "Alpha fact")
        ])
        let operation = Task {
            try await provider.summarize(document)
        }

        await driver.waitUntilSuspended()
        operation.cancel()
        await driver.resumeWithSuccess()

        await #expect(throws: IntelligenceError.cancelled) {
            try await operation.value
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

    @Test func legacyBudgetBoundsEscapedCompletePromptsAndItsSingleRetry() async throws {
        guard #available(macOS 26.0, *) else { return }

        let driver = PromptLengthGuardSessionDriver(
            maximumPromptCharacters: 4_608,
            overflowFirstCall: true
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: String(repeating: "&", count: 2_000))
        ])

        let result = try await provider.summarize(document)

        #expect(!result.text.isEmpty)
        #expect(await driver.acceptedPromptCount > 1)
    }

    @Test func legacyBudgetIncludesLongExtractionFieldNamesOutsideDocumentMarkup() async throws {
        guard #available(macOS 26.0, *) else { return }

        let longName = "field-" + String(repeating: "x", count: 1_800)
        let driver = ClosureFoundationModelsSessionDriver(
            extract: { _, prompt in
                guard prompt.count <= 4_608 else {
                    throw IntelligenceError.contextOverflow
                }
                return .init(fields: [])
            }
        )
        let provider = FoundationModelsIntelligenceProvider(
            availability: { .available },
            contextSize: 4_096,
            sessionDriver: driver
        )
        let document = IntelligenceDocument(pages: [
            .init(number: 1, text: String(repeating: "&", count: 1_000))
        ])

        let result = try await provider.extract([longName], from: document)

        #expect(result == [
            .init(name: longName, value: nil, sourcePage: nil, evidence: nil)
        ])
    }

    @Test(
        "Opt-in live Foundation Models smoke",
        .enabled(if: FoundationModelsLiveSmokeGate.isEnabledForCurrentProcess)
    )
    func optInLiveFoundationModelsSmokeUsesOnlySyntheticText() async throws {
        guard #available(macOS 26.0, *) else {
            Issue.record("Live Foundation Models smoke gate admitted macOS earlier than 26")
            return
        }

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

    @Test func liveSmokeGateRequiresBothExplicitOptInAndMacOS26() {
        #expect(!FoundationModelsLiveSmokeGate.isEnabled(flag: nil, macOSMajorVersion: 26))
        #expect(!FoundationModelsLiveSmokeGate.isEnabled(flag: "0", macOSMajorVersion: 26))
        #expect(!FoundationModelsLiveSmokeGate.isEnabled(flag: "1", macOSMajorVersion: 25))
        #expect(FoundationModelsLiveSmokeGate.isEnabled(flag: "1", macOSMajorVersion: 26))
    }

    private static let document = IntelligenceDocument(pages: [
        .init(number: 2, text: "Beta fact"),
        .init(number: 1, text: "Alpha fact")
    ])
}

private enum FoundationModelsLiveSmokeGate {
    static var isEnabledForCurrentProcess: Bool {
        isEnabled(
            flag: ProcessInfo.processInfo.environment["LOCALOCR_RUN_FOUNDATION_MODELS_TESTS"],
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    static func isEnabled(flag: String?, macOSMajorVersion: Int) -> Bool {
        flag == "1" && macOSMajorVersion >= 26
    }
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

@available(macOS 26.0, *)
private actor PromptLengthGuardSessionDriver: FoundationModelsSessionDriving {
    private let maximumPromptCharacters: Int
    private let overflowFirstCall: Bool
    private var callCount = 0
    private(set) var acceptedPromptCount = 0

    init(maximumPromptCharacters: Int, overflowFirstCall: Bool) {
        self.maximumPromptCharacters = maximumPromptCharacters
        self.overflowFirstCall = overflowFirstCall
    }

    func summarize(prompt: String) async throws -> FoundationModelsGeneratedSummary {
        callCount += 1
        if overflowFirstCall && callCount == 1 {
            throw IntelligenceError.contextOverflow
        }
        guard prompt.count <= maximumPromptCharacters else {
            throw IntelligenceError.contextOverflow
        }
        acceptedPromptCount += 1
        return .init(items: [
            .init(text: "Grounded ampersand.", page: 1, evidence: "&")
        ])
    }

    func organize(prompt: String) async throws -> FoundationModelsGeneratedOrganization {
        .init(title: nil, category: nil, tags: [])
    }

    func extract(names: [String], prompt: String) async throws -> FoundationModelsGeneratedExtraction {
        .init(fields: [])
    }
}

@available(macOS 26.0, *)
private actor SuspendedSuccessSessionDriver: FoundationModelsSessionDriving {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?

    func waitUntilSuspended() async {
        guard responseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiter = continuation
        }
    }

    func resumeWithSuccess() {
        responseContinuation?.resume()
        responseContinuation = nil
    }

    func summarize(prompt: String) async throws -> FoundationModelsGeneratedSummary {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            suspensionWaiter?.resume()
            suspensionWaiter = nil
        }
        return .init(items: [
            .init(text: "Late success.", page: 1, evidence: "Alpha fact")
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

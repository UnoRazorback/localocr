import Darwin
import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalModelQualificationServiceTests {
    @Test func qualificationRequiresAllThreeActionsAndCachesNoReceiptForAPartialPass() async throws {
        let provider = Task6FixtureProvider(extraction: [
            .init(name: "date", value: "2026-08-29", sourcePage: 1, evidence: "Date: 2026-08-29"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: nil, sourcePage: nil, evidence: nil)
        ])
        let service = task6QualificationService(provider: provider)

        let outcome = try await service.qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["extraction"])
        #expect(await service.cachedOutcome(for: task6OllamaIdentity)?.status == .failed)
    }

    @Test func qualificationPassesOnlyForExactGroundedFactsWithCorrectPageEvidence() async throws {
        let service = task6QualificationService(provider: Task6FixtureProvider())

        let outcome = try await service.qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.receipt?.identity == task6OllamaIdentity)
        #expect(outcome.receipt?.passedActions == Set(LocalIntelligenceAction.allCases))
        #expect(outcome.receipt?.fixtureVersion == 1)
        #expect(outcome.receipt?.policyVersion == 1)
        #expect(outcome.receipt?.qualifiedAt == task6Now)
    }

    @Test func extractionWithWrongPageEvidenceCannotProduceASelectableReceipt() async throws {
        let provider = Task6FixtureProvider(extraction: [
            .init(name: "date", value: "2026-08-29", sourcePage: 2, evidence: "synthetic test only"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: "Q-104", sourcePage: 1, evidence: "Invoice Q-104")
        ])

        let outcome = try await task6QualificationService(provider: provider).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["extraction"])
    }

    @Test func organizationWithAnUngroundedTagCannotProduceASelectableReceipt() async throws {
        let provider = Task6FixtureProvider(organization: .init(
            title: "Invoice Q-104",
            category: "LocalOCR Qualification",
            tags: ["unsupported remote claim"],
            citations: [
                .init(page: 1, quote: "Invoice Q-104"),
                .init(page: 2, quote: "LocalOCR Qualification")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["organization"])
    }

    @Test func cachedQualificationBecomesStaleForIdentityHarnessFixtureOrPolicyChanges() async throws {
        let service = task6QualificationService(provider: Task6FixtureProvider())
        let passed = try #require(try await service.qualify(task6OllamaIdentity).receipt)
        let changedHarness = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: task6OllamaIdentity.fingerprint,
            harnessVersion: "0.11.9"
        )
        let changedFingerprint = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: "sha256:changed",
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let staleFixture = LocalModelQualificationReceipt(
            policyVersion: 1,
            fixtureVersion: 2,
            identity: task6OllamaIdentity,
            passedActions: Set(LocalIntelligenceAction.allCases),
            qualifiedAt: task6Now
        )
        let stalePolicy = LocalModelQualificationReceipt(
            policyVersion: 2,
            fixtureVersion: 1,
            identity: task6OllamaIdentity,
            passedActions: Set(LocalIntelligenceAction.allCases),
            qualifiedAt: task6Now
        )

        #expect(await service.cachedOutcome(for: changedHarness)?.status == .stale)
        #expect(await service.cachedOutcome(for: changedFingerprint)?.status == .stale)
        #expect(service.status(for: task6OllamaIdentity, receipt: passed) == .passed)
        #expect(service.status(for: task6OllamaIdentity, receipt: staleFixture) == .stale)
        #expect(service.status(for: task6OllamaIdentity, receipt: stalePolicy) == .stale)
    }

    @Test func immutableFixtureContainsOnlyTheApprovedSyntheticFacts() throws {
        let fixture = try LocalModelQualificationService.loadFixture()

        #expect(fixture.version == 1)
        #expect(fixture.document == IntelligenceDocument(pages: [
            .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
            .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
        ]))
        #expect(fixture.fields == ["date", "total", "reference_number"])
    }

    @Test func passedQualificationCacheSurvivesAServiceRelaunch() async throws {
        let base = try task6PhysicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "localocr-task6-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try #require(chmod(base.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheDirectory = base.appending(path: "qualification", directoryHint: .isDirectory)
        let first = LocalModelQualificationService(
            providerFactory: { _ in Task6FixtureProvider() },
            now: { task6Now },
            cacheDirectory: cacheDirectory
        )
        _ = try await first.qualify(task6OllamaIdentity)
        let relaunched = LocalModelQualificationService(
            providerFactory: { _ in
                Issue.record("Reading the cache must not invoke a model")
                return Task6FixtureProvider()
            },
            now: { task6Now },
            cacheDirectory: cacheDirectory
        )

        let cached = await relaunched.cachedOutcome(for: task6OllamaIdentity)

        #expect(cached?.status == .passed)
        #expect(cached?.receipt == task6QualificationReceipt())
    }
}

let task6Now = Date(timeIntervalSince1970: 1_788_307_200)
let task6OllamaIdentity = LocalModelIdentity(
    provider: .ollama,
    model: "gemma4:8b",
    fingerprint: "sha256:fixture",
    harnessVersion: "0.11.8"
)
let task6LMStudioIdentity = LocalModelIdentity(
    provider: .lmStudio,
    model: "local/fixture-model",
    fingerprint: "sha256:lm-fixture",
    harnessVersion: "0.3.29"
)

func task6QualificationReceipt(
    identity: LocalModelIdentity = task6OllamaIdentity,
    policyVersion: Int = 1,
    fixtureVersion: Int = 1
) -> LocalModelQualificationReceipt {
    LocalModelQualificationReceipt(
        policyVersion: policyVersion,
        fixtureVersion: fixtureVersion,
        identity: identity,
        passedActions: Set(LocalIntelligenceAction.allCases),
        qualifiedAt: task6Now
    )
}

func task6Acknowledgment(
    identity: LocalModelIdentity = task6OllamaIdentity,
    policyVersion: Int = 1
) -> ExternalLocalModelAcknowledgment {
    ExternalLocalModelAcknowledgment(
        policyVersion: policyVersion,
        identity: identity,
        acceptedAt: task6Now
    )
}

func task6ExternalSelection(
    identity: LocalModelIdentity = task6OllamaIdentity,
    qualification: LocalModelQualificationReceipt? = nil,
    acknowledgment: ExternalLocalModelAcknowledgment? = nil
) -> LocalIntelligenceSelection {
    .external(
        identity: identity,
        qualification: qualification ?? task6QualificationReceipt(identity: identity),
        acknowledgment: acknowledgment ?? task6Acknowledgment(identity: identity)
    )
}

func task6QualificationService(
    provider: any DocumentIntelligenceProviding
) -> LocalModelQualificationService {
    LocalModelQualificationService(
        providerFactory: { _ in provider },
        now: { task6Now },
        cacheDirectory: nil
    )
}

actor Task6FixtureProvider: DocumentIntelligenceProviding {
    nonisolated let availability: IntelligenceAvailability = .available
    private let provenance: LocalModelProvenance
    private let summary: IntelligenceSummary
    private let organization: OrganizationSuggestion
    private let extraction: [ExtractedDocumentField]
    private let failure: (any Error)?
    private(set) var summaryCount = 0
    private(set) var organizationCount = 0
    private(set) var extractionCount = 0

    init(
        identity: LocalModelIdentity = task6OllamaIdentity,
        summary: IntelligenceSummary = .init(
            text: "Invoice Q-104 totals $144.17 on 2026-08-29.",
            citations: [.init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")]
        ),
        organization: OrganizationSuggestion = .init(
            title: "Invoice Q-104",
            category: "LocalOCR Qualification",
            tags: ["synthetic test only"],
            citations: [
                .init(page: 1, quote: "Invoice Q-104"),
                .init(page: 2, quote: "LocalOCR Qualification"),
                .init(page: 2, quote: "synthetic test only")
            ]
        ),
        extraction: [ExtractedDocumentField] = [
            .init(name: "date", value: "2026-08-29", sourcePage: 1, evidence: "Date: 2026-08-29"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: "Q-104", sourcePage: 1, evidence: "Invoice Q-104")
        ],
        failure: (any Error)? = nil
    ) {
        provenance = LocalModelProvenance(
            provider: identity.provider,
            providerDisplayName: identity.provider == .ollama ? "Ollama" : "LM Studio",
            model: identity.model,
            processing: .onDeviceLoopback,
            fingerprint: identity.fingerprint,
            qualifiedAt: task6Now
        )
        self.summary = summary
        self.organization = organization
        self.extraction = extraction
        self.failure = failure
    }

    func summarize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        _ = document
        summaryCount += 1
        if let failure { throw failure }
        return .init(value: summary, model: provenance)
    }

    func organize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        _ = document
        organizationCount += 1
        if let failure { throw failure }
        return .init(value: organization, model: provenance)
    }

    func extract(_ names: [String], from document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        _ = names
        _ = document
        extractionCount += 1
        if let failure { throw failure }
        return .init(value: extraction, model: provenance)
    }
}

actor Task6SelectionStore: LocalIntelligenceSelectionStoring {
    private var storedState: LocalIntelligenceSelectionState
    private(set) var writes: [LocalIntelligenceSelectionState] = []

    init(_ state: LocalIntelligenceSelectionState) {
        storedState = state
    }

    func state() async -> LocalIntelligenceSelectionState { storedState }

    func setState(_ state: LocalIntelligenceSelectionState) {
        storedState = state
    }

    func selectApple(at date: Date) async throws {
        _ = date
        storedState = .selected(.appleSystemDefault)
        writes.append(storedState)
    }

    func selectExternal(
        _ identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) async throws {
        storedState = .selected(.external(
            identity: identity,
            qualification: qualification,
            acknowledgment: acknowledgment
        ))
        writes.append(storedState)
    }

    func reset(at date: Date) async throws {
        _ = date
        storedState = .none
        writes.append(storedState)
    }
}

actor Task6Transport: ModelBridgeTransporting {
    typealias Handler = @Sendable (ModelBridgeRequest) async throws -> ModelBridgeResponse
    private let handler: Handler
    private(set) var requests: [ModelBridgeRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse {
        requests.append(request)
        return try await handler(request)
    }
}

final class Task6LocatorSpy: ModelBridgeExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var resolutionCount: Int { lock.withLock { count } }

    func executableURL() throws -> URL {
        lock.withLock { count += 1 }
        throw ModelBridgeExecutableLocatorError.helperNotFound
    }
}

func task6Candidate(
    identity: LocalModelIdentity = task6OllamaIdentity,
    locality: LocalModelLocality = .verifiedLocal,
    reason: String = "Verified local fixture"
) -> BridgeModelCandidate {
    BridgeModelCandidate(
        identity: identity,
        displayName: identity.model,
        locality: locality,
        localityReason: reason
    )
}

func task6DiscoveryResponse(
    request: ModelBridgeRequest,
    candidates: [BridgeModelCandidate]
) -> ModelBridgeResponse {
    ModelBridgeResponse(id: request.id, candidates: candidates)
}

func task6GeneratedPayload(for operation: ModelBridgeOperation) -> String {
    switch operation {
    case .summarize:
        return #"{"items":[{"text":"Invoice Q-104 totals $144.17.","page":1,"evidence":"Invoice Q-104. Date: 2026-08-29. Total: $144.17."}]}"#
    case .organize:
        return #"{"title":{"value":"Invoice Q-104","page":1,"evidence":"Invoice Q-104"},"category":{"value":"LocalOCR Qualification","page":2,"evidence":"LocalOCR Qualification"},"tags":[]}"#
    case .extract:
        return #"{"fields":[{"name":"date","value":"2026-08-29","page":1,"evidence":"Date: 2026-08-29"},{"name":"total","value":"$144.17","page":1,"evidence":"Total: $144.17"},{"name":"reference_number","value":"Q-104","page":1,"evidence":"Invoice Q-104"}]}"#
    }
}

func task6PhysicalURL(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
        throw CocoaError(.fileNoSuchFile)
    }
    let path = String(
        decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    return URL(fileURLWithPath: path, isDirectory: true)
}

import Foundation
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore

public actor LocalIntelligenceProviderRouter: DocumentIntelligenceProviding {
    public typealias AppleProviderFactory = @Sendable () -> any DocumentIntelligenceProviding

    private let selectionStore: any LocalIntelligenceSelectionStoring
    private let transport: any ModelBridgeTransporting
    private let appleProviderFactory: AppleProviderFactory
    private var requestID: UInt64 = 1

    public init(
        selectionStore: any LocalIntelligenceSelectionStoring,
        transport: any ModelBridgeTransporting,
        appleProviderFactory: @escaping AppleProviderFactory
    ) {
        self.selectionStore = selectionStore
        self.transport = transport
        self.appleProviderFactory = appleProviderFactory
    }

    public var availability: IntelligenceAvailability {
        get async {
            do {
                return await (try resolvedProvider()).availability
            } catch {
                return .modelNotReady
            }
        }
    }

    public func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        try await resolvedProvider().summarize(document)
    }

    public func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        try await resolvedProvider().organize(document)
    }

    public func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        try await resolvedProvider().extract(names, from: document)
    }

    private func resolvedProvider() async throws -> any DocumentIntelligenceProviding {
        switch await selectionStore.state() {
        case .none:
            throw IntelligenceError.selection(.corruptReceipt)
        case let .invalid(failure):
            throw IntelligenceError.selection(failure)
        case .selected(.appleSystemDefault):
            return appleProviderFactory()
        case let .selected(.external(identity, qualification, acknowledgment)):
            try Self.validate(
                identity: identity,
                qualification: qualification,
                acknowledgment: acknowledgment
            )
            let currentIdentity = try await verifiedCurrentIdentity(identity)
            return BridgeBackedIntelligenceProvider(
                identity: currentIdentity,
                qualifiedAt: qualification.qualifiedAt,
                transport: transport
            )
        }
    }

    private func verifiedCurrentIdentity(
        _ selected: LocalModelIdentity
    ) async throws -> LocalModelIdentity {
        let id = nextRequestID()
        let response: ModelBridgeResponse
        do {
            response = try await transport.send(.discover(id: id, provider: selected.provider))
        } catch {
            throw IntelligenceError.selection(.providerUnavailable(selected.provider))
        }
        if let error = response.error {
            throw Self.mappedWireError(error, expected: selected)
        }

        let sameModel = response.candidates.filter {
            $0.identity.provider == selected.provider && $0.identity.model == selected.model
        }
        guard !sameModel.isEmpty else {
            throw IntelligenceError.selection(.modelUnavailable(selected))
        }
        guard sameModel.count == 1, let candidate = sameModel.first else {
            throw IntelligenceError.selection(.identityChanged(expected: selected, actual: nil))
        }
        guard candidate.identity == selected else {
            throw IntelligenceError.selection(.identityChanged(
                expected: selected,
                actual: candidate.identity
            ))
        }
        switch candidate.locality {
        case .verifiedLocal:
            return candidate.identity
        case .unverified:
            throw IntelligenceError.selection(.localityUnverified(candidate.identity))
        case .blocked:
            throw IntelligenceError.selection(.localityBlocked(candidate.identity))
        }
    }

    private func nextRequestID() -> UInt64 {
        defer { requestID &+= 1 }
        return requestID
    }

    private nonisolated static func validate(
        identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) throws {
        guard identity.provider != .appleFoundationModels,
              !identity.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(identity.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              !(identity.harnessVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              qualification.policyVersion == LocalModelQualificationReceipt.currentPolicyVersion,
              qualification.fixtureVersion == LocalModelQualificationReceipt.currentFixtureVersion,
              qualification.identity == identity,
              qualification.passedActions == Set(LocalIntelligenceAction.allCases)
        else {
            throw IntelligenceError.selection(.qualificationRequired(identity))
        }
        guard acknowledgment.policyVersion == ExternalLocalModelAcknowledgment.currentPolicyVersion,
              acknowledgment.identity == identity
        else {
            throw IntelligenceError.selection(.acknowledgmentRequired(identity))
        }
    }

    nonisolated static func mappedWireError(
        _ error: ModelBridgeWireError,
        expected: LocalModelIdentity
    ) -> IntelligenceError {
        switch error.code {
        case .modelIdentityChanged:
            .selection(.identityChanged(expected: expected, actual: nil))
        case .providerUnavailable:
            .selection(.providerUnavailable(expected.provider))
        case .generationFailed:
            .ungroundedOutput
        case .invalidRequest, .messageTooLarge, .unsupportedVersion, .providerNotImplemented:
            .selection(.providerUnavailable(expected.provider))
        }
    }
}

actor BridgeBackedIntelligenceProvider: DocumentIntelligenceProviding {
    private let identity: LocalModelIdentity
    private let qualifiedAt: Date
    private let driver: BridgeStructuredIntelligenceSessionDriver
    private let engine: GroundedDocumentIntelligenceProvider

    init(
        identity: LocalModelIdentity,
        qualifiedAt: Date,
        transport: any ModelBridgeTransporting
    ) {
        self.identity = identity
        self.qualifiedAt = qualifiedAt
        let driver = BridgeStructuredIntelligenceSessionDriver(
            identity: identity,
            transport: transport
        )
        self.driver = driver
        engine = GroundedDocumentIntelligenceProvider(
            availability: { .available },
            provenance: Self.provenance(identity: identity, qualifiedAt: qualifiedAt),
            sessionDriver: driver
        )
    }

    var availability: IntelligenceAvailability { get async { .available } }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        await driver.resetActualIdentity()
        let result = try await engine.summarize(document)
        return .init(
            value: result.value,
            model: try await actualProvenance()
        )
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        await driver.resetActualIdentity()
        let result = try await engine.organize(document)
        return .init(
            value: result.value,
            model: try await actualProvenance()
        )
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        await driver.resetActualIdentity()
        let result = try await engine.extract(names, from: document)
        return .init(
            value: result.value,
            model: try await actualProvenance()
        )
    }

    private func actualProvenance() async throws -> LocalModelProvenance {
        guard let actual = await driver.actualIdentity else {
            throw IntelligenceError.selection(.providerUnavailable(identity.provider))
        }
        return Self.provenance(identity: actual, qualifiedAt: qualifiedAt)
    }

    private nonisolated static func provenance(
        identity: LocalModelIdentity,
        qualifiedAt: Date
    ) -> LocalModelProvenance {
        LocalModelProvenance(
            provider: identity.provider,
            providerDisplayName: identity.provider == .ollama ? "Ollama" : "LM Studio",
            model: identity.model,
            processing: .onDeviceLoopback,
            fingerprint: identity.fingerprint,
            qualifiedAt: qualifiedAt
        )
    }
}

private actor BridgeStructuredIntelligenceSessionDriver: StructuredIntelligenceSessionDriving {
    nonisolated let contextSize = 4_096

    private struct SummaryPayload: Decodable {
        struct Item: Decodable {
            let text: String
            let page: Int
            let evidence: String
        }
        let items: [Item]
    }

    private struct OrganizationPayload: Decodable {
        struct Fact: Decodable {
            let value: String
            let page: Int
            let evidence: String
        }
        let title: Fact?
        let category: Fact?
        let tags: [Fact]
    }

    private struct ExtractionPayload: Decodable {
        struct Field: Decodable {
            let name: String
            let value: String?
            let page: Int?
            let evidence: String?
        }
        let fields: [Field]
    }

    private let identity: LocalModelIdentity
    private let transport: any ModelBridgeTransporting
    private var requestID: UInt64 = 10_000
    private(set) var actualIdentity: LocalModelIdentity?

    init(identity: LocalModelIdentity, transport: any ModelBridgeTransporting) {
        self.identity = identity
        self.transport = transport
    }

    func resetActualIdentity() {
        actualIdentity = nil
    }

    func summarize(prompt: String) async throws -> GeneratedSummary {
        let payload: SummaryPayload = try await generate(
            operation: .summarize,
            prompt: prompt,
            fields: []
        )
        return GeneratedSummary(items: payload.items.map {
            GeneratedSummaryItem(text: $0.text, page: $0.page, evidence: $0.evidence)
        })
    }

    func organize(prompt: String) async throws -> GeneratedOrganization {
        let payload: OrganizationPayload = try await generate(
            operation: .organize,
            prompt: prompt,
            fields: []
        )
        return GeneratedOrganization(
            title: payload.title.map { GeneratedFact(value: $0.value, page: $0.page, evidence: $0.evidence) },
            category: payload.category.map { GeneratedFact(value: $0.value, page: $0.page, evidence: $0.evidence) },
            tags: payload.tags.map { GeneratedFact(value: $0.value, page: $0.page, evidence: $0.evidence) }
        )
    }

    func extract(names: [String], prompt: String) async throws -> GeneratedExtraction {
        let payload: ExtractionPayload = try await generate(
            operation: .extract,
            prompt: prompt,
            fields: names
        )
        return GeneratedExtraction(fields: payload.fields.map {
            GeneratedField(
                name: $0.name,
                value: $0.value,
                page: $0.page,
                evidence: $0.evidence
            )
        })
    }

    private func generate<Payload: Decodable>(
        operation: ModelBridgeOperation,
        prompt: String,
        fields: [String]
    ) async throws -> Payload {
        let id = nextRequestID()
        let response: ModelBridgeResponse
        do {
            response = try await transport.send(.generate(
                id: id,
                provider: identity.provider,
                model: identity.model,
                operation: operation,
                prompt: prompt,
                fields: fields
            ))
        } catch is CancellationError {
            throw IntelligenceError.cancelled
        } catch {
            throw IntelligenceError.selection(.providerUnavailable(identity.provider))
        }
        if let error = response.error {
            throw LocalIntelligenceProviderRouter.mappedWireError(error, expected: identity)
        }
        guard let actual = response.identity else {
            throw IntelligenceError.selection(.identityChanged(expected: identity, actual: nil))
        }
        guard actual == identity else {
            throw IntelligenceError.selection(.identityChanged(expected: identity, actual: actual))
        }
        guard let payloadJSON = response.payloadJSON else {
            throw IntelligenceError.ungroundedOutput
        }
        guard Self.hasClosedSchema(payloadJSON, operation: operation) else {
            throw IntelligenceError.ungroundedOutput
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(payloadJSON.utf8))
        } catch {
            throw IntelligenceError.ungroundedOutput
        }
        actualIdentity = actual
        return payload
    }

    private nonisolated static func hasClosedSchema(
        _ payloadJSON: String,
        operation: ModelBridgeOperation
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)),
              let members = object as? [String: Any]
        else {
            return false
        }
        switch operation {
        case .summarize:
            guard Set(members.keys) == ["items"],
                  let items = members["items"] as? [Any]
            else { return false }
            return items.allSatisfy { hasExactKeys($0, ["text", "page", "evidence"]) }
        case .organize:
            guard Set(members.keys) == ["title", "category", "tags"],
                  optionalFactHasClosedSchema(members["title"]),
                  optionalFactHasClosedSchema(members["category"]),
                  let tags = members["tags"] as? [Any]
            else { return false }
            return tags.allSatisfy { hasExactKeys($0, ["value", "page", "evidence"]) }
        case .extract:
            guard Set(members.keys) == ["fields"],
                  let fields = members["fields"] as? [Any]
            else { return false }
            return fields.allSatisfy {
                hasExactKeys($0, ["name", "value", "page", "evidence"])
            }
        }
    }

    private nonisolated static func optionalFactHasClosedSchema(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return true }
        return hasExactKeys(value, ["value", "page", "evidence"])
    }

    private nonisolated static func hasExactKeys(
        _ value: Any,
        _ keys: Set<String>
    ) -> Bool {
        guard let members = value as? [String: Any] else { return false }
        return Set(members.keys) == keys
    }

    private func nextRequestID() -> UInt64 {
        defer { requestID &+= 1 }
        return requestID
    }
}

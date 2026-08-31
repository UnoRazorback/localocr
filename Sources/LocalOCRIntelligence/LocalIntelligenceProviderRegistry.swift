import Foundation
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore

public protocol LocalIntelligenceManaging: Sendable {
    func models() async -> [LocalModelDescriptor]
    func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome
    func selectApple() async throws
    func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws
    func status() async -> LocalIntelligenceSelectionState
    func reset() async throws
}

public protocol LocalIntelligenceAppleDescribing: Sendable {
    func appleModel() async -> LocalModelDescriptor
}

public struct LocalModelDescriptor: Sendable, Equatable {
    public let identity: LocalModelIdentity
    public let displayName: String
    public let locality: LocalModelLocality
    public let localityReason: String
    public let qualification: LocalModelQualificationStatus
    public let available: Bool
    public let selected: Bool
    public let qualifiedAt: Date?

    public init(
        identity: LocalModelIdentity,
        displayName: String,
        locality: LocalModelLocality,
        localityReason: String,
        qualification: LocalModelQualificationStatus,
        available: Bool,
        selected: Bool
    ) {
        self.init(
            identity: identity,
            displayName: displayName,
            locality: locality,
            localityReason: localityReason,
            qualification: qualification,
            available: available,
            selected: selected,
            qualifiedAt: nil
        )
    }

    public init(
        identity: LocalModelIdentity,
        displayName: String,
        locality: LocalModelLocality,
        localityReason: String,
        qualification: LocalModelQualificationStatus,
        available: Bool,
        selected: Bool,
        qualifiedAt: Date?
    ) {
        self.identity = identity
        self.displayName = displayName
        self.locality = locality
        self.localityReason = localityReason
        self.qualification = qualification
        self.available = available
        self.selected = selected
        self.qualifiedAt = qualifiedAt
    }
}

public actor LocalIntelligenceProviderRegistry: LocalIntelligenceManaging, LocalIntelligenceAppleDescribing {
    public typealias AppleProviderFactory = @Sendable () -> any DocumentIntelligenceProviding

    private let transport: any ModelBridgeTransporting
    private let selectionStore: any LocalIntelligenceSelectionStoring
    private let qualificationService: LocalModelQualificationService
    private let appleProviderFactory: AppleProviderFactory
    private let now: @Sendable () -> Date
    private var requestID: UInt64 = 100

    public init(
        transport: any ModelBridgeTransporting,
        selectionStore: any LocalIntelligenceSelectionStoring,
        qualificationService: LocalModelQualificationService,
        appleProviderFactory: @escaping AppleProviderFactory,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.selectionStore = selectionStore
        self.qualificationService = qualificationService
        self.appleProviderFactory = appleProviderFactory
        self.now = now
    }

    public func models() async -> [LocalModelDescriptor] {
        let selectionState = await selectionStore.state()
        var result = [await appleDescriptor(selectionState: selectionState)]

        var discovered: [BridgeModelCandidate] = []
        for provider in [LocalModelProviderID.ollama, .lmStudio] {
            if let candidates = try? await discover(provider, expected: nil) {
                discovered.append(contentsOf: candidates)
            }
        }

        for candidate in Self.uniqueCandidates(discovered) {
            let state = await descriptorState(
                for: candidate,
                selectionState: selectionState
            )
            result.append(LocalModelDescriptor(
                identity: candidate.identity,
                displayName: candidate.displayName,
                locality: candidate.locality,
                localityReason: candidate.localityReason,
                qualification: state.qualification,
                available: true,
                selected: state.selected,
                qualifiedAt: state.qualifiedAt
            ))
        }

        if case let .selected(.external(identity, qualification, _)) = selectionState,
           !discovered.contains(where: { $0.identity == identity }) {
            let changedIdentityExists = discovered.contains {
                $0.identity.provider == identity.provider && $0.identity.model == identity.model
            }
            if !changedIdentityExists {
                result.append(LocalModelDescriptor(
                    identity: identity,
                    displayName: identity.model,
                    locality: .verifiedLocal,
                    localityReason: "Selected model is currently unavailable.",
                    qualification: qualificationService.status(
                        for: identity,
                        receipt: qualification
                    ),
                    available: false,
                    selected: true,
                    qualifiedAt: qualification.qualifiedAt
                ))
            }
        }

        return result.sorted(by: Self.descriptorOrder)
    }

    public func appleModel() async -> LocalModelDescriptor {
        await appleDescriptor(selectionState: selectionStore.state())
    }

    private func appleDescriptor(
        selectionState: LocalIntelligenceSelectionState
    ) async -> LocalModelDescriptor {
        let appleAvailable = await appleProviderFactory().availability == .available
        return LocalModelDescriptor(
            identity: .appleSystemDefault,
            displayName: "Apple Foundation Models — system default",
            locality: .verifiedLocal,
            localityReason: "Built into macOS and runs on device.",
            qualification: .passed,
            available: appleAvailable,
            selected: selectionState == .selected(.appleSystemDefault),
            qualifiedAt: nil
        )
    }

    public func qualify(
        _ identity: LocalModelIdentity
    ) async throws -> LocalModelQualificationOutcome {
        _ = try await verifiedCandidate(identity)
        return try await qualificationService.qualify(identity)
    }

    public func selectApple() async throws {
        try await selectionStore.selectApple(at: now())
    }

    public func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws {
        _ = try await verifiedCandidate(identity)
        guard let outcome = await qualificationService.cachedOutcome(for: identity),
              outcome.status == .passed,
              let receipt = outcome.receipt,
              qualificationService.status(for: identity, receipt: receipt) == .passed
        else {
            throw IntelligenceError.selection(.qualificationRequired(identity))
        }
        let acknowledgment = ExternalLocalModelAcknowledgment(
            policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
            identity: identity,
            acceptedAt: acknowledgmentAcceptedAt
        )
        try await selectionStore.selectExternal(
            identity,
            qualification: receipt,
            acknowledgment: acknowledgment
        )
    }

    public func status() async -> LocalIntelligenceSelectionState {
        await selectionStore.state()
    }

    public func reset() async throws {
        try await selectionStore.reset(at: now())
    }

    private func descriptorState(
        for candidate: BridgeModelCandidate,
        selectionState: LocalIntelligenceSelectionState
    ) async -> (qualification: LocalModelQualificationStatus, selected: Bool, qualifiedAt: Date?) {
        if case let .selected(.external(identity, qualification, acknowledgment)) = selectionState {
            if identity == candidate.identity {
                let qualificationStatus = qualificationService.status(
                    for: identity,
                    receipt: qualification
                )
                let acknowledgmentCurrent = acknowledgment.policyVersion ==
                    ExternalLocalModelAcknowledgment.currentPolicyVersion &&
                    acknowledgment.identity == identity
                return (
                    acknowledgmentCurrent ? qualificationStatus : .stale,
                    candidate.locality == .verifiedLocal &&
                        qualificationStatus == .passed &&
                        acknowledgmentCurrent,
                    qualification.qualifiedAt
                )
            }
            if identity.provider == candidate.identity.provider,
               identity.model == candidate.identity.model {
                return (.stale, false, nil)
            }
        }
        let cached = await qualificationService.cachedOutcome(for: candidate.identity)
        return (cached?.status ?? .untested, false, cached?.receipt?.qualifiedAt)
    }

    private func verifiedCandidate(
        _ identity: LocalModelIdentity
    ) async throws -> BridgeModelCandidate {
        let candidates = try await discover(identity.provider, expected: identity)
        let sameModel = candidates.filter {
            $0.identity.provider == identity.provider && $0.identity.model == identity.model
        }
        guard !sameModel.isEmpty else {
            throw IntelligenceError.selection(.modelUnavailable(identity))
        }
        guard sameModel.count == 1, let candidate = sameModel.first else {
            throw IntelligenceError.bridgeInvalid
        }
        guard candidate.identity == identity else {
            throw IntelligenceError.selection(.identityChanged(
                expected: identity,
                actual: candidate.identity
            ))
        }
        switch candidate.locality {
        case .verifiedLocal:
            return candidate
        case .blocked:
            throw IntelligenceError.selection(.localityBlocked(identity))
        case .unverified:
            throw IntelligenceError.selection(.localityUnverified(identity))
        }
    }

    private func discover(
        _ provider: LocalModelProviderID,
        expected: LocalModelIdentity?
    ) async throws -> [BridgeModelCandidate] {
        guard provider == .ollama || provider == .lmStudio else {
            throw IntelligenceError.selection(.providerUnavailable(provider))
        }
        let id = nextRequestID()
        let response: ModelBridgeResponse
        do {
            response = try await transport.send(.discover(id: id, provider: provider))
        } catch {
            throw LocalIntelligenceProviderRouter.mappedTransportError(error)
        }
        if let error = response.error {
            let mappedIdentity = expected ?? LocalModelIdentity(
                provider: provider,
                model: "unavailable",
                fingerprint: nil,
                harnessVersion: nil
            )
            throw LocalIntelligenceProviderRouter.mappedWireError(error, expected: mappedIdentity)
        }
        return response.candidates.filter { $0.identity.provider == provider }
    }

    private func nextRequestID() -> UInt64 {
        defer { requestID &+= 1 }
        return requestID
    }

    private nonisolated static func uniqueCandidates(
        _ candidates: [BridgeModelCandidate]
    ) -> [BridgeModelCandidate] {
        var seen: Set<LocalModelIdentity> = []
        return candidates.filter { seen.insert($0.identity).inserted }
    }

    private nonisolated static func descriptorOrder(
        _ lhs: LocalModelDescriptor,
        _ rhs: LocalModelDescriptor
    ) -> Bool {
        let providerOrder: [LocalModelProviderID: Int] = [
            .appleFoundationModels: 0,
            .ollama: 1,
            .lmStudio: 2
        ]
        let lhsOrder = providerOrder[lhs.identity.provider] ?? 3
        let rhsOrder = providerOrder[rhs.identity.provider] ?? 3
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs.identity.model < rhs.identity.model
    }
}

import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import LocalOCRStudioKit
import Testing

@Suite struct StudioLocalModelManagerViewModelTests {
    @Test @MainActor func detectKeepsProviderOrderAndShowsBlockedModelsWithoutSelection() async {
        let manager = FixtureStudioModelManager(descriptors: [
            descriptor(.lmStudio, model: "zeta", locality: .unverified),
            descriptor(.ollama, model: "cloud-model", locality: .blocked),
            descriptor(.appleFoundationModels, model: "SystemLanguageModel.default", qualification: .passed),
            descriptor(.ollama, model: "alpha", qualification: .passed),
        ])
        let model = StudioLocalModelManagerViewModel(manager: manager)

        await model.detect()

        #expect(model.models.map(\.identity.provider) == [
            .appleFoundationModels, .ollama, .ollama, .lmStudio,
        ])
        let blocked = model.models.first { $0.identity.model == "cloud-model" }
        #expect(blocked?.statusText == "Blocked: cloud or remote execution")
        #expect(blocked?.canTest == false)
        #expect(blocked?.canSelect == false)
        #expect(await manager.calls() == [.models, .status])
    }

    @Test @MainActor func testUsesExactIdentityAndPublishesQualificationTimestamp() async throws {
        let identity = externalIdentity(.ollama, model: "gemma4:8b")
        let qualifiedAt = Date(timeIntervalSince1970: 1_788_050_400)
        let manager = FixtureStudioModelManager(
            descriptors: [descriptor(identity, qualification: .untested)],
            qualificationOutcomes: [identity: qualification(identity, at: qualifiedAt)]
        )
        let model = StudioLocalModelManagerViewModel(manager: manager)
        await model.detect()

        await model.test(identity)

        let row = try #require(model.models.first { $0.identity == identity })
        #expect(row.qualification == .passed)
        #expect(row.qualifiedAt == qualifiedAt)
        #expect(row.statusText == "Qualified · Local")
        #expect(row.canSelect)
        #expect(await manager.calls().contains(.qualify(identity)))
    }

    @Test @MainActor func externalSelectionRequiresExactConfirmationAndCancelNeverMutates() async throws {
        let identity = externalIdentity(.lmStudio, model: "qwen2.5\u{202E}:7b")
        let manager = FixtureStudioModelManager(
            descriptors: [descriptor(identity, qualification: .passed)]
        )
        let model = StudioLocalModelManagerViewModel(manager: manager)
        await model.detect()

        model.prepareExternalSelection(identity)

        let confirmation = try #require(model.externalConfirmation)
        #expect(confirmation.identity == identity)
        #expect(confirmation.providerName == "LM Studio")
        #expect(confirmation.modelName == "qwen2.5:7b")
        #expect(confirmation.statement == StudioExternalModelConfirmation.approvedStatement)
        #expect(await manager.externalSelections().isEmpty)

        model.cancelExternalSelection()
        #expect(model.pendingExternalIdentity == nil)
        #expect(await manager.externalSelections().isEmpty)

        model.prepareExternalSelection(identity)
        await model.confirmExternalSelection()
        #expect(await manager.externalSelections() == [identity])
        #expect(model.pendingExternalIdentity == nil)
    }

    @Test @MainActor func changedIdentityDuringConfirmationFailsClosed() async {
        let identity = externalIdentity(.ollama, model: "gemma4:8b")
        let manager = FixtureStudioModelManager(
            descriptors: [descriptor(identity, qualification: .passed)],
            selectionError: .selection(.identityChanged(expected: identity, actual: nil))
        )
        let model = StudioLocalModelManagerViewModel(manager: manager)
        await model.detect()
        model.prepareExternalSelection(identity)

        await model.confirmExternalSelection()

        #expect(model.selection == .selected(.appleSystemDefault))
        #expect(model.pendingExternalIdentity == nil)
        #expect(model.error?.title == "Model Changed")
        #expect(await manager.externalSelections().isEmpty)
    }

    @Test @MainActor func presentedErrorCanBeDismissedWithoutChangingSelection() async {
        let identity = externalIdentity(.ollama, model: "gemma4:8b")
        let manager = FixtureStudioModelManager(
            descriptors: [descriptor(identity, locality: .blocked)]
        )
        let model = StudioLocalModelManagerViewModel(manager: manager)
        await model.detect()

        model.prepareExternalSelection(identity)
        #expect(model.error?.title == "Model Cannot Be Selected")

        model.dismissError()

        #expect(model.error == nil)
        #expect(model.selection == .selected(.appleSystemDefault))
        #expect(await manager.externalSelections().isEmpty)
    }

    @Test @MainActor func AppleSelectionNeedsNoConfirmationAndResetIsExplicit() async {
        let manager = FixtureStudioModelManager(descriptors: [
            descriptor(.appleFoundationModels, model: "SystemLanguageModel.default", qualification: .passed)
        ])
        let model = StudioLocalModelManagerViewModel(manager: manager)
        await model.detect()

        await model.selectApple()
        #expect(model.externalConfirmation == nil)
        #expect(await manager.appleSelectionCount() == 1)

        await model.reset()
        #expect(model.selection == .reset(at: FixtureStudioModelManager.now))
        #expect(await manager.resetCount() == 1)
    }

    @Test @MainActor func lateDetectionCannotReplaceNewerDetection() async {
        let slow = descriptor(.ollama, model: "old", qualification: .passed)
        let current = descriptor(.lmStudio, model: "current", qualification: .passed)
        let manager = SequencedStudioModelManager(responses: [[slow], [current]])
        let model = StudioLocalModelManagerViewModel(manager: manager)

        let first = Task { await model.detect() }
        await manager.waitForRequest(1)
        let second = Task { await model.detect() }
        await manager.waitForRequest(2)
        await manager.resume(request: 2)
        await second.value
        await manager.resume(request: 1)
        await first.value

        #expect(model.models.map(\.identity.model) == ["current"])
    }
}

private actor FixtureStudioModelManager: LocalIntelligenceManaging {
    enum Call: Sendable, Equatable {
        case models
        case qualify(LocalModelIdentity)
        case status
        case selectApple
        case selectExternal(LocalModelIdentity)
        case reset
    }

    static let now = Date(timeIntervalSince1970: 1_788_050_400)
    private var descriptors: [LocalModelDescriptor]
    private let qualificationOutcomes: [LocalModelIdentity: LocalModelQualificationOutcome]
    private let selectionError: IntelligenceError?
    private var selectionState: LocalIntelligenceSelectionState = .selected(.appleSystemDefault)
    private var recordedCalls: [Call] = []
    private var selectedExternalIdentities: [LocalModelIdentity] = []
    private var selectedAppleCount = 0
    private var recordedResetCount = 0

    init(
        descriptors: [LocalModelDescriptor],
        qualificationOutcomes: [LocalModelIdentity: LocalModelQualificationOutcome] = [:],
        selectionError: IntelligenceError? = nil
    ) {
        self.descriptors = descriptors
        self.qualificationOutcomes = qualificationOutcomes
        self.selectionError = selectionError
    }

    func models() async -> [LocalModelDescriptor] {
        recordedCalls.append(.models)
        return descriptors
    }

    func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
        recordedCalls.append(.qualify(identity))
        let outcome = qualificationOutcomes[identity] ?? qualification(identity, at: Self.now)
        descriptors = descriptors.map { descriptor in
            guard descriptor.identity == identity else { return descriptor }
            return LocalModelDescriptor(
                identity: descriptor.identity,
                displayName: descriptor.displayName,
                locality: descriptor.locality,
                localityReason: descriptor.localityReason,
                qualification: outcome.status,
                available: descriptor.available,
                selected: descriptor.selected,
                qualifiedAt: outcome.receipt?.qualifiedAt
            )
        }
        return outcome
    }

    func selectApple() async throws {
        recordedCalls.append(.selectApple)
        selectedAppleCount += 1
        selectionState = .selected(.appleSystemDefault)
    }

    func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws {
        _ = acknowledgmentAcceptedAt
        recordedCalls.append(.selectExternal(identity))
        if let selectionError { throw selectionError }
        selectedExternalIdentities.append(identity)
        selectionState = .selected(.external(
            identity: identity,
            qualification: qualification(identity, at: Self.now).receipt!,
            acknowledgment: ExternalLocalModelAcknowledgment(
                policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
                identity: identity,
                acceptedAt: Self.now
            )
        ))
    }

    func status() async -> LocalIntelligenceSelectionState {
        recordedCalls.append(.status)
        return selectionState
    }

    func reset() async throws {
        recordedCalls.append(.reset)
        recordedResetCount += 1
        selectionState = .reset(at: Self.now)
    }

    func calls() -> [Call] { recordedCalls }
    func externalSelections() -> [LocalModelIdentity] { selectedExternalIdentities }
    func appleSelectionCount() -> Int { selectedAppleCount }
    func resetCount() -> Int { recordedResetCount }
}

private actor SequencedStudioModelManager: LocalIntelligenceManaging {
    private let responses: [[LocalModelDescriptor]]
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(responses: [[LocalModelDescriptor]]) { self.responses = responses }

    func models() async -> [LocalModelDescriptor] {
        requestCount += 1
        let request = requestCount
        let listeners = waiters.removeValue(forKey: request) ?? []
        listeners.forEach { $0.resume() }
        await withCheckedContinuation { continuations[request] = $0 }
        return responses[request - 1]
    }

    func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
        qualification(identity, at: FixtureStudioModelManager.now)
    }
    func selectApple() async throws {}
    func selectExternal(_ identity: LocalModelIdentity, acknowledgmentAcceptedAt: Date) async throws {}
    func status() async -> LocalIntelligenceSelectionState { .selected(.appleSystemDefault) }
    func reset() async throws {}

    func waitForRequest(_ request: Int) async {
        guard requestCount < request else { return }
        await withCheckedContinuation { waiters[request, default: []].append($0) }
    }

    func resume(request: Int) { continuations.removeValue(forKey: request)?.resume() }
}

private func externalIdentity(
    _ provider: LocalModelProviderID,
    model: String
) -> LocalModelIdentity {
    LocalModelIdentity(
        provider: provider,
        model: model,
        fingerprint: "sha256:fixture",
        harnessVersion: "1.0.0"
    )
}

private func descriptor(
    _ provider: LocalModelProviderID,
    model: String,
    locality: LocalModelLocality = .verifiedLocal,
    qualification: LocalModelQualificationStatus = .untested
) -> LocalModelDescriptor {
    let identity = provider == .appleFoundationModels
        ? LocalModelIdentity.appleSystemDefault
        : externalIdentity(provider, model: model)
    return descriptor(identity, locality: locality, qualification: qualification)
}

private func descriptor(
    _ identity: LocalModelIdentity,
    locality: LocalModelLocality = .verifiedLocal,
    qualification: LocalModelQualificationStatus = .untested
) -> LocalModelDescriptor {
    let reason: String = switch locality {
    case .verifiedLocal: "Inference is local to this Mac."
    case .blocked: "cloud or remote execution"
    case .unverified: "local execution could not be verified"
    }
    return LocalModelDescriptor(
        identity: identity,
        displayName: identity.model,
        locality: locality,
        localityReason: reason,
        qualification: qualification,
        available: true,
        selected: identity == .appleSystemDefault,
        qualifiedAt: nil
    )
}

private func qualification(
    _ identity: LocalModelIdentity,
    at date: Date
) -> LocalModelQualificationOutcome {
    LocalModelQualificationOutcome(
        status: .passed,
        receipt: LocalModelQualificationReceipt(
            policyVersion: LocalModelQualificationReceipt.currentPolicyVersion,
            fixtureVersion: LocalModelQualificationReceipt.currentFixtureVersion,
            identity: identity,
            passedActions: Set(LocalIntelligenceAction.allCases),
            qualifiedAt: date
        ),
        failures: []
    )
}

import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalIntelligenceProviderRegistryTests {
    @Test func modelsDiscoveryIsContentFreeAndReturnsApplePlusBridgeCandidates() async {
        let llamaIdentity = LocalModelIdentity(provider: .llamaCpp, model: "fixture", fingerprint: "sha256:fixture", harnessVersion: "fixture")
        let transport = Task6Transport { request in
            #expect(request.action == .discover)
            #expect(request.prompt == nil)
            #expect(request.model == nil)
            #expect(request.fields.isEmpty)
            let candidates = request.provider == .ollama
                ? [task6Candidate()]
                : [task6Candidate(identity: request.provider == .llamaCpp ? llamaIdentity : task6LMStudioIdentity)]
            return task6DiscoveryResponse(request: request, candidates: candidates)
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: Task6SelectionStore(.none),
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        let models = await registry.models()

        #expect(models.map(\.identity) == [
            .appleSystemDefault,
            task6OllamaIdentity,
            task6LMStudioIdentity, llamaIdentity
        ])
        #expect(models.first?.available == true)
        #expect(await transport.requests.count == 3)
        #expect(await transport.requests.allSatisfy { $0.action == .discover && $0.prompt == nil })
    }

    @Test func modelsMergesCurrentSelectionQualificationAndAcknowledgmentWithoutRewritingIt() async {
        let selection = task6ExternalSelection()
        let store = Task6SelectionStore(.selected(selection))
        let transport = Task6Transport { request in
            task6DiscoveryResponse(
                request: request,
                candidates: request.provider == .ollama ? [task6Candidate()] : []
            )
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: store,
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        let models = await registry.models()
        let ollama = models.first { $0.identity == task6OllamaIdentity }

        #expect(ollama?.qualification == .passed)
        #expect(ollama?.available == true)
        #expect(ollama?.selected == true)
        #expect(await store.writes.isEmpty)
    }

    @Test func selectedIdentityThatChangedIsShownAsStaleAndNotSelected() async {
        let changed = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: "sha256:changed",
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let transport = Task6Transport { request in
            task6DiscoveryResponse(
                request: request,
                candidates: request.provider == .ollama ? [task6Candidate(identity: changed)] : []
            )
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: Task6SelectionStore(.selected(task6ExternalSelection())),
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        let models = await registry.models()
        let changedDescriptor = models.first { $0.identity == changed }

        #expect(changedDescriptor?.qualification == .stale)
        #expect(changedDescriptor?.selected == false)
    }

    @Test func statusRevalidatesSelectedExternalIdentityAgainstLiveDiscovery() async {
        let storedSelection = task6ExternalSelection()
        let store = Task6SelectionStore(.selected(storedSelection))
        let transport = Task6Transport { request in
            #expect(request.action == .discover)
            #expect(request.provider == .ollama)
            #expect(request.prompt == nil)
            return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: store,
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        #expect(await registry.status() == .selected(storedSelection))
        #expect(await transport.requests.count == 1)
    }

    @Test func statusInvalidatesSelectedExternalIdentityWhenLiveIdentityChanged() async {
        let changed = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: "sha256:changed",
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let transport = Task6Transport { request in
            task6DiscoveryResponse(request: request, candidates: [task6Candidate(identity: changed)])
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: Task6SelectionStore(.selected(task6ExternalSelection())),
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        #expect(await registry.status() == .invalid(.identityChanged(
            expected: task6OllamaIdentity,
            actual: changed
        )))
    }

    @Test func statusInvalidatesSelectedExternalIdentityWhenProviderCannotBeReached() async {
        let transport = Task6Transport { _ in
            throw ModelBridgeClientError.helperLaunchFailed
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: Task6SelectionStore(.selected(task6ExternalSelection())),
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        #expect(await registry.status() == .invalid(.providerUnavailable(.ollama)))
    }

    @Test func statusDoesNotProbeBridgeForAppleSelection() async {
        let transport = Task6Transport { _ in
            Issue.record("Apple status must not probe the external model bridge")
            throw ModelBridgeClientError.helperLaunchFailed
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: Task6SelectionStore(.selected(.appleSystemDefault)),
            qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        #expect(await registry.status() == .selected(.appleSystemDefault))
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [LocalModelProviderID.ollama, .lmStudio, .llamaCpp])
    func freshQualificationAfterIdentityChangeIsDiscoverableWithoutReset(provider: LocalModelProviderID) async throws {
        func identity(processID: Int32) -> LocalModelIdentity {
            LocalModelIdentity(provider: provider, model: "fixture.gguf",
                fingerprint: provider == .llamaCpp ? String(repeating: "a", count: 64) : "sha256:\(processID)",
                harnessVersion: "fixture", fileAttestation: provider == .llamaCpp ? LocalModelFileAttestation(
                    executablePath: "/private/tmp/fixture/llama-server", executableSHA256: String(repeating: "b", count: 64),
                    modelPath: "/private/tmp/fixture/model.gguf", modelSize: 1024, modelModifiedNanoseconds: 1,
                    executableSize: 1024, executableModifiedNanoseconds: 1, processID: processID
                ) : nil)
        }
        let old = identity(processID: 123)
        let current = identity(processID: 456)
        let originalSelection = task6ExternalSelection(identity: old)
        let store = Task6SelectionStore(.selected(originalSelection))
        let qualification = task6QualificationService(provider: Task6FixtureProvider(identity: current))
        let transport = Task6Transport { request in
            #expect(request.action == .discover)
            #expect(request.prompt == nil)
            return task6DiscoveryResponse(request: request,
                candidates: request.provider == current.provider ? [task6Candidate(identity: current)] : [])
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport, selectionStore: store, qualificationService: qualification,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) }, now: { task6Now }
        )
        let before = await registry.models().first { $0.identity == current }
        #expect(before?.qualification == .stale)
        let outcome = try await registry.qualify(current)
        #expect(outcome.status == .passed)
        let refreshed = await registry.models().first { $0.identity == current }
        #expect(refreshed?.qualification == .passed)
        #expect(refreshed?.qualifiedAt == outcome.receipt?.qualifiedAt)
        #expect(refreshed?.selected == false)
        #expect(await store.state() == .selected(originalSelection))
        #expect(await store.writes.isEmpty)

        let router = LocalIntelligenceProviderRouter(
            selectionStore: store, transport: transport,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) }
        )
        await #expect(throws: IntelligenceError.selection(.identityChanged(expected: old, actual: current))) {
            try await router.summarize(task6Document)
        }
        #expect(await transport.requests.allSatisfy { $0.action == .discover && $0.prompt == nil })
        try await registry.selectExternal(current, acknowledgmentAcceptedAt: task6Now)
        #expect(await store.state() == .selected(task6ExternalSelection(identity: current,
            qualification: outcome.receipt)))
    }

    @Test func selectExternalRequiresCurrentVerifiedIdentityQualificationAndFreshAcknowledgment() async throws {
        let store = Task6SelectionStore(.none)
        let provider = Task6FixtureProvider()
        let qualification = task6QualificationService(provider: provider)
        _ = try await qualification.qualify(task6OllamaIdentity)
        let transport = Task6Transport { request in
            task6DiscoveryResponse(
                request: request,
                candidates: request.provider == .ollama ? [task6Candidate()] : []
            )
        }
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: store,
            qualificationService: qualification,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        try await registry.selectExternal(task6OllamaIdentity, acknowledgmentAcceptedAt: task6Now)

        #expect(await store.state() == .selected(task6ExternalSelection()))
    }

    @Test func resetPreservesPopulatedQualificationHistory() async throws {
        let store = Task6SelectionStore(.selected(task6ExternalSelection()))
        let qualification = task6QualificationService(provider: Task6FixtureProvider())
        let qualified = try await qualification.qualify(task6OllamaIdentity)
        let registry = LocalIntelligenceProviderRegistry(
            transport: Task6Transport { request in
                task6DiscoveryResponse(request: request, candidates: [])
            },
            selectionStore: store,
            qualificationService: qualification,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            now: { task6Now }
        )

        try await registry.reset()

        #expect(await store.state() == .reset(at: task6Now))
        #expect(await qualification.cachedOutcome(for: task6OllamaIdentity) == qualified)
    }

    @Test func blockedOrUnverifiedCandidateCannotBeSelected() async throws {
        for identity in [task6OllamaIdentity, task6LMStudioIdentity] {
            for locality in [LocalModelLocality.blocked, .unverified] {
                let store = Task6SelectionStore(.none)
                let qualification = task6QualificationService(
                    provider: Task6FixtureProvider(identity: identity)
                )
                _ = try await qualification.qualify(identity)
                let transport = Task6Transport { request in
                    task6DiscoveryResponse(
                        request: request,
                        candidates: request.provider == identity.provider
                            ? [task6Candidate(identity: identity, locality: locality)]
                            : []
                    )
                }
                let registry = LocalIntelligenceProviderRegistry(
                    transport: transport,
                    selectionStore: store,
                    qualificationService: qualification,
                    appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
                    now: { task6Now }
                )

                let expected = locality == .blocked
                    ? LocalIntelligenceSelectionFailure.localityBlocked(identity)
                    : LocalIntelligenceSelectionFailure.localityUnverified(identity)
                await #expect(throws: IntelligenceError.selection(expected)) {
                    try await registry.selectExternal(identity, acknowledgmentAcceptedAt: task6Now)
                }
                #expect(await store.state() == .none)
            }
        }
    }

    @Test func ambiguousDuplicateCandidateFailsAsInvalidBridgeForBothExternalProviders() async throws {
        for identity in [task6OllamaIdentity, task6LMStudioIdentity] {
            let store = Task6SelectionStore(.none)
            let qualification = task6QualificationService(
                provider: Task6FixtureProvider(identity: identity)
            )
            _ = try await qualification.qualify(identity)
            let duplicate = task6Candidate(identity: identity)
            let transport = Task6Transport { request in
                task6DiscoveryResponse(
                    request: request,
                    candidates: request.provider == identity.provider ? [duplicate, duplicate] : []
                )
            }
            let registry = LocalIntelligenceProviderRegistry(
                transport: transport,
                selectionStore: store,
                qualificationService: qualification,
                appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
                now: { task6Now }
            )

            await #expect(throws: IntelligenceError.bridgeInvalid) {
                try await registry.selectExternal(identity, acknowledgmentAcceptedAt: task6Now)
            }
            #expect(await store.state() == .none)
        }
    }

    @Test func oneObservedAlternateIdentityReportsIdentityChangeForBothExternalProviders() async throws {
        for identity in [task6OllamaIdentity, task6LMStudioIdentity] {
            let changed = LocalModelIdentity(
                provider: identity.provider,
                model: identity.model,
                fingerprint: "sha256:changed",
                harnessVersion: identity.harnessVersion
            )
            let qualification = task6QualificationService(
                provider: Task6FixtureProvider(identity: identity)
            )
            _ = try await qualification.qualify(identity)
            let transport = Task6Transport { request in
                task6DiscoveryResponse(
                    request: request,
                    candidates: request.provider == identity.provider
                        ? [task6Candidate(identity: changed)]
                        : []
                )
            }
            let registry = LocalIntelligenceProviderRegistry(
                transport: transport,
                selectionStore: Task6SelectionStore(.none),
                qualificationService: qualification,
                appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
                now: { task6Now }
            )

            await #expect(throws: IntelligenceError.selection(.identityChanged(
                expected: identity,
                actual: changed
            ))) {
                try await registry.selectExternal(identity, acknowledgmentAcceptedAt: task6Now)
            }
        }
    }

    @Test func qualificationDiscoveryPreservesHelperProtocolAndCancellationFailures() async {
        enum Fixture: Sendable {
            case helper
            case malformedProtocol
            case oversizedResponse
            case cancellation
        }
        let fixtures: [(Fixture, IntelligenceError)] = [
            (.helper, .bridgeUnavailable),
            (.malformedProtocol, .bridgeInvalid),
            (.oversizedResponse, .bridgeInvalid),
            (.cancellation, .cancelled)
        ]

        for (fixture, expected) in fixtures {
            let transport = Task6Transport { _ in
                switch fixture {
                case .helper:
                    throw ModelBridgeClientError.helperLaunchFailed
                case .malformedProtocol:
                    throw ModelBridgeClientError.malformedResponse
                case .oversizedResponse:
                    throw ModelBridgeClientError.responseTooLarge
                case .cancellation:
                    throw CancellationError()
                }
            }
            let registry = LocalIntelligenceProviderRegistry(
                transport: transport,
                selectionStore: Task6SelectionStore(.none),
                qualificationService: task6QualificationService(provider: Task6FixtureProvider()),
                appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
                now: { task6Now }
            )

            do {
                _ = try await registry.qualify(task6OllamaIdentity)
                Issue.record("Expected stable registry failure \(expected)")
            } catch let actual as IntelligenceError {
                #expect(actual == expected)
            } catch {
                Issue.record("Unexpected registry failure: \(error)")
            }
        }
    }
}

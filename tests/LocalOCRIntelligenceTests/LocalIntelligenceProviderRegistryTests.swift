import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalIntelligenceProviderRegistryTests {
    @Test func modelsDiscoveryIsContentFreeAndReturnsApplePlusBridgeCandidates() async {
        let transport = Task6Transport { request in
            #expect(request.action == .discover)
            #expect(request.prompt == nil)
            #expect(request.model == nil)
            #expect(request.fields.isEmpty)
            let candidates = request.provider == .ollama
                ? [task6Candidate()]
                : [task6Candidate(identity: task6LMStudioIdentity)]
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
            task6LMStudioIdentity
        ])
        #expect(models.first?.available == true)
        #expect(await transport.requests.count == 2)
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

    @Test func blockedOrUnverifiedCandidateCannotBeSelected() async throws {
        for locality in [LocalModelLocality.blocked, .unverified] {
            let store = Task6SelectionStore(.none)
            let qualification = task6QualificationService(provider: Task6FixtureProvider())
            _ = try await qualification.qualify(task6OllamaIdentity)
            let transport = Task6Transport { request in
                task6DiscoveryResponse(
                    request: request,
                    candidates: request.provider == .ollama
                        ? [task6Candidate(locality: locality)]
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
                ? LocalIntelligenceSelectionFailure.localityBlocked(task6OllamaIdentity)
                : LocalIntelligenceSelectionFailure.localityUnverified(task6OllamaIdentity)
            await #expect(throws: IntelligenceError.selection(expected)) {
                try await registry.selectExternal(task6OllamaIdentity, acknowledgmentAcceptedAt: task6Now)
            }
            #expect(await store.state() == .none)
        }
    }
}

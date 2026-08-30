import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalIntelligenceProviderRouterTests {
    @Test func unavailableSelectedModelNeverFallsBackToApple() async {
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let transport = Task6Transport { request in
            ModelBridgeResponse(
                id: request.id,
                error: .init(code: .providerUnavailable, message: "stopped")
            )
        }
        let router = task6Router(transport: transport, apple: apple)

        await #expect(throws: IntelligenceError.selection(.providerUnavailable(.ollama))) {
            try await router.summarize(task6Document)
        }
        #expect(await apple.summaryCount == 0)
    }

    @Test func blockedAndUnverifiedSelectionsFailClosedWithoutGenerationOrApple() async {
        for locality in [LocalModelLocality.blocked, .unverified] {
            let apple = Task6FixtureProvider(identity: .appleSystemDefault)
            let transport = Task6Transport { request in
                task6DiscoveryResponse(
                    request: request,
                    candidates: [task6Candidate(locality: locality)]
                )
            }
            let router = task6Router(transport: transport, apple: apple)
            let expected = locality == .blocked
                ? LocalIntelligenceSelectionFailure.localityBlocked(task6OllamaIdentity)
                : LocalIntelligenceSelectionFailure.localityUnverified(task6OllamaIdentity)

            await #expect(throws: IntelligenceError.selection(expected)) {
                try await router.summarize(task6Document)
            }
            #expect(await transport.requests.count == 1)
            #expect(await apple.summaryCount == 0)
        }
    }

    @Test func discoveryIdentityChangeFailsBeforeSendingDocumentText() async {
        let changed = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: "sha256:changed",
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let transport = Task6Transport { request in
            task6DiscoveryResponse(request: request, candidates: [task6Candidate(identity: changed)])
        }
        let router = task6Router(transport: transport, apple: apple)

        await #expect(throws: IntelligenceError.selection(.identityChanged(
            expected: task6OllamaIdentity,
            actual: changed
        ))) {
            try await router.summarize(task6Document)
        }
        #expect(await transport.requests.allSatisfy { $0.prompt == nil })
        #expect(await apple.summaryCount == 0)
    }

    @Test func selectedExternalIdentityWithoutImmutableEvidenceFailsBeforeDiscovery() async {
        let incomplete = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: nil,
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let transport = Task6Transport { request in
            Issue.record("Incomplete identity must fail before bridge discovery")
            return ModelBridgeResponse(id: request.id)
        }
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let router = task6Router(
            transport: transport,
            apple: apple,
            state: .selected(task6ExternalSelection(identity: incomplete))
        )

        await #expect(throws: IntelligenceError.selection(.qualificationRequired(incomplete))) {
            try await router.summarize(task6Document)
        }
        #expect(await transport.requests.isEmpty)
        #expect(await apple.summaryCount == 0)
    }

    @Test func identityChangingBetweenDiscoveryAndGenerationDiscardsOutputWithoutAppleFallback() async {
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let transport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            return ModelBridgeResponse(
                id: request.id,
                error: .init(code: .modelIdentityChanged, message: "changed")
            )
        }
        let router = task6Router(transport: transport, apple: apple)

        await #expect(throws: IntelligenceError.selection(.identityChanged(
            expected: task6OllamaIdentity,
            actual: nil
        ))) {
            try await router.summarize(task6Document)
        }
        #expect(await transport.requests.count == 2)
        #expect(await apple.summaryCount == 0)
    }

    @Test func bridgeFailureNeverInvokesApple() async {
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let transport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            throw ModelBridgeClientError.helperLaunchFailed
        }
        let router = task6Router(transport: transport, apple: apple)

        await #expect(throws: IntelligenceError.bridgeUnavailable) {
            try await router.summarize(task6Document)
        }
        #expect(await apple.summaryCount == 0)
    }

    @Test func bridgeAndGenerationFailuresMapToStableCategoriesWithoutFallback() async {
        enum Failure: Sendable {
            case transport(ModelBridgeClientError)
            case wire(ModelBridgeWireErrorCode)
        }
        let fixtures: [(Failure, IntelligenceError)] = [
            (.transport(.timedOut), .generationTimedOut),
            (.transport(.malformedResponse), .bridgeInvalid),
            (.transport(.responseTooLarge), .bridgeInvalid),
            (.transport(.helperLaunchFailed), .bridgeUnavailable),
            (.wire(.generationFailed), .generationFailed),
            (.wire(.contextOverflow), .contextOverflow),
            (.wire(.schemaFailure), .malformedOutput),
            (.wire(.groundingFailure), .ungroundedOutput),
            (.wire(.localityUnverified), .selection(.localityUnverified(task6OllamaIdentity)))
        ]

        for (fixture, expected) in fixtures {
            let apple = Task6FixtureProvider(identity: .appleSystemDefault)
            let transport = Task6Transport { request in
                if request.action == .discover {
                    return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
                }
                switch fixture {
                case let .transport(error):
                    throw error
                case let .wire(code):
                    return ModelBridgeResponse(
                        id: request.id,
                        error: .init(code: code, message: "fixture")
                    )
                }
            }

            do {
                _ = try await task6Router(transport: transport, apple: apple)
                    .summarize(task6Document)
                Issue.record("Expected stable failure \(expected)")
            } catch let actual as IntelligenceError {
                #expect(actual == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(await apple.summaryCount == 0)
        }
    }

    @Test func malformedBridgePayloadIsDiscardedWithoutAppleFallback() async {
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let transport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            return ModelBridgeResponse(
                id: request.id,
                payloadJSON: #"{"items":[{"text":"Invoice Q-104","page":1,"evidence":"Invoice Q-104"}],"unexpected":"secret"}"#,
                identity: task6OllamaIdentity
            )
        }
        let router = task6Router(transport: transport, apple: apple)

        await #expect(throws: IntelligenceError.malformedOutput) {
            try await router.summarize(task6Document)
        }
        #expect(await apple.summaryCount == 0)
    }

    @Test func organizeAndExtractExternalFailuresNeverFallBackToApple() async {
        let organizeApple = Task6FixtureProvider(identity: .appleSystemDefault)
        let organizeTransport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            throw ModelBridgeClientError.helperExited(status: 9)
        }
        await #expect(throws: IntelligenceError.bridgeUnavailable) {
            try await task6Router(transport: organizeTransport, apple: organizeApple)
                .organize(task6Document)
        }
        #expect(await organizeApple.organizationCount == 0)

        let extractApple = Task6FixtureProvider(identity: .appleSystemDefault)
        let extractTransport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            return ModelBridgeResponse(
                id: request.id,
                error: .init(code: .generationFailed, message: "failed")
            )
        }
        await #expect(throws: IntelligenceError.generationFailed) {
            try await task6Router(transport: extractTransport, apple: extractApple)
                .extract(["date"], from: task6Document)
        }
        #expect(await extractApple.extractionCount == 0)
    }

    @Test func successfulExternalResultUsesTheActualBridgeResponseProvenance() async throws {
        let transport = Task6Transport { request in
            if request.action == .discover {
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate()])
            }
            return ModelBridgeResponse(
                id: request.id,
                payloadJSON: task6GeneratedPayload(for: try #require(request.operation)),
                identity: task6OllamaIdentity
            )
        }
        let router = task6Router(
            transport: transport,
            apple: Task6FixtureProvider(identity: .appleSystemDefault)
        )

        let result = try await router.summarize(task6Document)

        #expect(result.model == LocalModelProvenance(
            provider: .ollama,
            providerDisplayName: "Ollama",
            model: task6OllamaIdentity.model,
            processing: .onDeviceLoopback,
            fingerprint: task6OllamaIdentity.fingerprint,
            qualifiedAt: task6Now
        ))
        #expect(result.value.citations == [
            .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
        ])
    }

    @Test func everyOperationRereadsSelectionAndForwardsStaleReceiptFailures() async throws {
        let store = Task6SelectionStore(.selected(.appleSystemDefault))
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let router = LocalIntelligenceProviderRouter(
            selectionStore: store,
            transport: Task6Transport { request in ModelBridgeResponse(id: request.id) },
            appleProviderFactory: { apple }
        )

        _ = try await router.summarize(task6Document)
        await store.setState(.invalid(.acknowledgmentRequired(task6OllamaIdentity)))

        await #expect(throws: IntelligenceError.selection(.acknowledgmentRequired(task6OllamaIdentity))) {
            try await router.organize(task6Document)
        }
        #expect(await apple.organizationCount == 0)
    }

    @Test func environmentConstructionAndAppleOrNonePathsNeverResolveTheBridgeHelper() async throws {
        let locator = Task6LocatorSpy()
        let appleStore = Task6SelectionStore(.selected(.appleSystemDefault))
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let appleEnvironment = LocalIntelligenceEnvironment.live(
            bridgeLocator: locator,
            selectionStore: appleStore,
            appleProviderFactory: { apple },
            now: { task6Now }
        )

        #expect(locator.resolutionCount == 0)
        _ = try await appleEnvironment.router.summarize(task6Document)
        #expect(locator.resolutionCount == 0)

        let noneEnvironment = LocalIntelligenceEnvironment.live(
            bridgeLocator: locator,
            selectionStore: Task6SelectionStore(.none),
            appleProviderFactory: { apple },
            now: { task6Now }
        )
        await #expect(throws: IntelligenceError.selection(.corruptReceipt)) {
            try await noneEnvironment.router.summarize(task6Document)
        }
        #expect(locator.resolutionCount == 0)
    }
}

let task6Document = IntelligenceDocument(pages: [
    .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
    .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
])

func task6Router(
    transport: any ModelBridgeTransporting,
    apple: any DocumentIntelligenceProviding,
    state: LocalIntelligenceSelectionState = .selected(task6ExternalSelection())
) -> LocalIntelligenceProviderRouter {
    LocalIntelligenceProviderRouter(
        selectionStore: Task6SelectionStore(state),
        transport: transport,
        appleProviderFactory: { apple }
    )
}

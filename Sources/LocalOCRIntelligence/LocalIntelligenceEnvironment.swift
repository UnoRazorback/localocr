import Foundation

public struct LocalIntelligenceEnvironment: Sendable {
    public let manager: any LocalIntelligenceManaging
    public let router: any DocumentIntelligenceProviding
    public let selectionStore: any LocalIntelligenceSelectionStoring

    public init(
        manager: any LocalIntelligenceManaging,
        router: any DocumentIntelligenceProviding,
        selectionStore: any LocalIntelligenceSelectionStoring
    ) {
        self.manager = manager
        self.router = router
        self.selectionStore = selectionStore
    }

    public static func live(
        bridgeLocator: any ModelBridgeExecutableLocating
    ) -> LocalIntelligenceEnvironment {
        live(
            bridgeLocator: bridgeLocator,
            selectionStore: LocalIntelligenceSelectionStore(),
            appleProviderFactory: liveAppleProvider,
            now: Date.init
        )
    }

    static func live(
        bridgeLocator: any ModelBridgeExecutableLocating,
        selectionStore: any LocalIntelligenceSelectionStoring,
        appleProviderFactory: @escaping @Sendable () -> any DocumentIntelligenceProviding,
        now: @escaping @Sendable () -> Date
    ) -> LocalIntelligenceEnvironment {
        let transport = StdioModelBridgeClient(executableLocator: bridgeLocator)
        let qualification = LocalModelQualificationService(
            providerFactory: { identity in
                BridgeBackedIntelligenceProvider(
                    identity: identity,
                    qualifiedAt: now(),
                    transport: transport
                )
            },
            now: now
        )
        let registry = LocalIntelligenceProviderRegistry(
            transport: transport,
            selectionStore: selectionStore,
            qualificationService: qualification,
            appleProviderFactory: appleProviderFactory,
            now: now
        )
        let router = LocalIntelligenceProviderRouter(
            selectionStore: selectionStore,
            transport: transport,
            appleProviderFactory: appleProviderFactory
        )
        return LocalIntelligenceEnvironment(
            manager: registry,
            router: router,
            selectionStore: selectionStore
        )
    }

    private static func liveAppleProvider() -> any DocumentIntelligenceProviding {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsIntelligenceProvider()
        }
        #endif
        return UnavailableIntelligenceProvider(.requiresMacOS26)
    }
}

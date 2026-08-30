import Foundation
import LocalOCRModelCore
import Testing

@Suite struct LocalModelTypesTests {
    @Test func appleProvenanceIsTruthfulAndExternalIdentityRoundTrips() throws {
        #expect(LocalModelProvenance.appleSystemDefault.provider == .appleFoundationModels)
        #expect(LocalModelProvenance.appleSystemDefault.model == "SystemLanguageModel.default")
        #expect(LocalModelProvenance.appleSystemDefault.processing == .onDevice)

        let identity = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:abc",
            harnessVersion: "0.13.0"
        )
        #expect(
            try JSONDecoder().decode(
                LocalModelIdentity.self,
                from: JSONEncoder().encode(identity)
            ) == identity
        )
    }
}

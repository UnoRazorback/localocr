import Darwin
import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeKit
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LlamaCppQualificationTests {
    @Test func allThreeAdapterOperationsQualifyAndPersistExactFileIdentity() async throws {
        let base = try task6PhysicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("llama-qualification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try #require(chmod(base.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = base.appendingPathComponent("qualification")
        let http = QualificationLlamaHTTP()
        let adapter = LlamaCppBridgeAdapter(http: http, probe: QualificationLlamaProbe())
        let identity = try #require(try await adapter.discover().first?.identity)
        let transport = QualificationLlamaTransport(adapter: adapter)
        let factory: LocalModelQualificationService.ProviderFactory = { identity in
            BridgeBackedIntelligenceProvider(identity: identity, qualifiedAt: task6Now, transport: transport)
        }
        let service = LocalModelQualificationService(providerFactory: factory, now: { task6Now }, cacheDirectory: cache)
        let outcome = try await service.qualify(identity)
        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
        let receipt = try #require(outcome.receipt)
        #expect(receipt.passedActions == Set(LocalIntelligenceAction.allCases))
        let operations = await http.generated
        #expect(operations.contains(.summarize))
        #expect(operations.contains(.organize))
        #expect(operations.contains(.extract))
        let relaunched = LocalModelQualificationService(providerFactory: factory, now: { task6Now }, cacheDirectory: cache)
        #expect(await relaunched.cachedOutcome(for: identity)?.receipt == receipt)

        let selectionURL = base.appendingPathComponent("selection/receipt.json")
        let store = LocalIntelligenceSelectionStore(receiptURL: selectionURL)
        let acknowledgment = ExternalLocalModelAcknowledgment(policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
            identity: identity, acceptedAt: task6Now)
        try await store.selectExternal(identity, qualification: receipt, acknowledgment: acknowledgment)
        let reloaded = LocalIntelligenceSelectionStore(receiptURL: selectionURL)
        #expect(await reloaded.state() == .selected(.external(identity: identity, qualification: receipt, acknowledgment: acknowledgment)))
        let saved = String(decoding: try Data(contentsOf: selectionURL), as: UTF8.self)
        #expect(saved.contains("fileAttestation"))
        #expect(saved.contains(String(repeating: "b", count: 64)))

        // Unknown nested identity keys cannot survive the protected receipt decoder.
        let corrupted = saved.replacingOccurrences(of: "\"executableSHA256\":", with: "\"unknown\":true,\"executableSHA256\":")
        let handle = try FileHandle(forWritingTo: selectionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(corrupted.utf8))
        try handle.close()
        #expect(await reloaded.state() == .invalid(.corruptReceipt))
    }
}

private struct QualificationLlamaProbe: LlamaCppProcessProbing {
    func snapshot() async throws -> LlamaCppProcessSnapshot {
        LlamaCppProcessSnapshot(alias: "qualification", modelPath: "/models/fixture.gguf",
            fingerprint: String(repeating: "a", count: 64), harnessVersion: "version: 1 (a2878d30d)",
            executablePath: "/opt/homebrew/bin/llama-server", executableSHA256: String(repeating: "b", count: 64),
            modelSize: 100, modelModifiedNanoseconds: 1, executableSize: 200,
            executableModifiedNanoseconds: 2, processID: 123)
    }
}

private struct QualificationLlamaTransport: ModelBridgeTransporting {
    let adapter: LlamaCppBridgeAdapter
    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse { await adapter.generate(request) }
}

private actor QualificationLlamaHTTP: LoopbackHTTPPerforming {
    var generated: [ModelBridgeOperation] = []
    func perform(_ endpoint: ApprovedLoopbackEndpoint, body: Data?, timeoutMilliseconds: Int) async throws -> Data {
        let value: [String: Any]
        switch endpoint {
        case .llamaCppHealth: value = ["status": "ok"]
        case .llamaCppProps:
            value = ["model_path": "/models/fixture.gguf", "model_alias": "qualification", "total_slots": 1,
                "modalities": ["vision": false, "audio": false, "video": false],
                "is_sleeping": false, "cors_proxy_enabled": false]
        case .llamaCppModels:
            value = ["object": "list", "data": [["id": "qualification", "object": "model"]]]
        case .llamaCppChat:
            let requestData = try #require(body)
            let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            let format = try #require(request["response_format"] as? [String: Any])
            let descriptor = try #require(format["json_schema"] as? [String: Any])
            let schema = try #require(descriptor["schema"] as? [String: Any])
            let props = try #require(schema["properties"] as? [String: Any])
            let operation: ModelBridgeOperation = props["items"] != nil ? .summarize : (props["tags"] != nil ? .organize : .extract)
            generated.append(operation)
            value = ["object": "chat.completion", "model": "qualification", "choices": [[
                "index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": task6GeneratedPayload(for: operation)]
            ]]]
        default: throw LoopbackHTTPError.nonLoopbackResponse
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

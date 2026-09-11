import Foundation
import LocalOCRModelCore
import LocalOCRModelBridgeProtocol
@testable import LocalOCRModelBridgeKit
import Testing

@Suite("Verified local llama.cpp adapter")
struct LlamaCppBridgeAdapterTests {
    private let snapshot = LlamaCppProcessSnapshot(
        alias: "fixture", modelPath: "/models/fixture.gguf", fingerprint: String(repeating: "a", count: 64),
        harnessVersion: "llama-server:test", executablePath: "/usr/local/bin/llama-server",
        executableSHA256: String(repeating: "b", count: 64), modelSize: 10,
        modelModifiedNanoseconds: 1, executableSize: 20, executableModifiedNanoseconds: 2,
        processID: 100
    )

    @Test func discoveryUsesOnlyMetadataAndPinsFiles() async throws {
        let http = LlamaHTTP()
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        let models = try await adapter.discover()
        #expect(models.count == 1)
        #expect(models[0].identity.fingerprint == snapshot.fingerprint)
        #expect(models[0].identity.fileAttestation?.executablePath == snapshot.executablePath)
        #expect(await http.endpoints == [.llamaCppHealth, .llamaCppProps, .llamaCppModels])
        #expect(await http.bodies.allSatisfy { $0 == nil })
    }

    @Test func mismatchNeverSendsDocument() async throws {
        let http = LlamaHTTP(alias: "other")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        let models = try await adapter.discover()
        #expect(models.first?.locality == .unverified)
        #expect(!(await http.endpoints).contains(.llamaCppChat))
    }

    @Test func generationUsesStrictSchemaAndIdenticalAttestation() async throws {
        let http = LlamaHTTP()
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        let identity = try #require(try await adapter.discover().first?.identity)
        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))
        #expect(response.error == nil)
        #expect(response.identity == identity)
        let body = try #require(await http.bodies.compactMap { $0 }.first)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["temperature"] as? Int == 0)
        #expect(object["n"] as? Int == 1)
        #expect(object["tool_choice"] as? String == "none")
        #expect(object["response_format"] != nil)
    }

    @Test func rejectsToolReasoningMultipleChoicesAndSchemaExtras() async throws {
        for mutation in ["tool", "reasoning", "choices", "extra", "payload", "model"] {
            let http = LlamaHTTP(mutation: mutation)
            let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
            let identity = try #require(try await adapter.discover().first?.identity)
            let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
                operation: .summarize, prompt: "Page 1: Fixture."))
            #expect(response.error?.code == .schemaFailure)
            #expect(response.payloadJSON == nil)
        }
    }

    @Test func changedMetadataAfterGenerationDiscardsOutput() async throws {
        let http = LlamaHTTP(mutation: "metadata")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        let identity = try #require(try await adapter.discover().first?.identity)
        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))
        #expect(response.error?.code == .modelIdentityChanged)
        #expect(response.payloadJSON == nil)
    }

    @Test func changedProcessAfterGenerationDiscardsOutput() async throws {
        let changed = LlamaCppProcessSnapshot(alias: snapshot.alias, modelPath: snapshot.modelPath,
            fingerprint: snapshot.fingerprint, harnessVersion: snapshot.harnessVersion,
            executablePath: snapshot.executablePath, executableSHA256: snapshot.executableSHA256,
            modelSize: snapshot.modelSize, modelModifiedNanoseconds: snapshot.modelModifiedNanoseconds,
            executableSize: snapshot.executableSize, executableModifiedNanoseconds: snapshot.executableModifiedNanoseconds,
            processID: snapshot.processID + 1)
        let adapter = LlamaCppBridgeAdapter(http: LlamaHTTP(), probe: ChangingLlamaProbe(before: snapshot, after: changed))
        let identity = try #require(try await adapter.discover().first?.identity)
        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))
        #expect(response.error?.code == .modelIdentityChanged)
        #expect(response.payloadJSON == nil)
    }

    @Test func discoveryDeadlineCancelsPendingMetadataRequest() async throws {
        let http = SlowLlamaHTTP()
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        await #expect(throws: LoopbackHTTPError.timedOut) {
            try await adapter.discover(timeoutMilliseconds: 1000)
        }
        #expect(await http.endpoints == [.llamaCppHealth])
    }

    @Test func cancelledDiscoveryDoesNotSendDocument() async throws {
        let http = SlowLlamaHTTP()
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: snapshot))
        let task = Task { try await adapter.discover() }
        while await http.endpoints.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected cancellation mapping: \(error)") }
        #expect(await http.endpoints == [.llamaCppHealth])
    }

    @Test func wireRoundTripPreservesFileAttestationAndRejectsAliasSpelling() async throws {
        let adapter = LlamaCppBridgeAdapter(http: LlamaHTTP(), probe: LlamaProbe(snapshot: snapshot))
        let identity = try #require(try await adapter.discover().first?.identity)
        let encoded = try JSONEncoder().encode(ModelBridgeRequest.generate(id: 1,
            expectedIdentity: identity, operation: .summarize, prompt: "fixture"))
        let decoded = try JSONDecoder().decode(ModelBridgeRequest.self, from: encoded)
        #expect(decoded.expectedIdentity == identity)
        let bad = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "llama_cpp", with: "llama.cpp")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelBridgeRequest.self, from: Data(bad.utf8)) }
    }
}

private struct LlamaProbe: LlamaCppProcessProbing {
    let value: LlamaCppProcessSnapshot
    init(snapshot: LlamaCppProcessSnapshot) { value = snapshot }
    func snapshot() async throws -> LlamaCppProcessSnapshot { value }
}

private actor LlamaHTTP: LoopbackHTTPPerforming {
    var endpoints: [ApprovedLoopbackEndpoint] = []
    var bodies: [Data?] = []
    let alias: String
    let mutation: String
    private var generated = false
    init(alias: String = "fixture", mutation: String = "") { self.alias = alias; self.mutation = mutation }
    func perform(_ endpoint: ApprovedLoopbackEndpoint, body: Data?, timeoutMilliseconds: Int) async throws -> Data {
        endpoints.append(endpoint); bodies.append(body)
        let object: [String: Any]
        switch endpoint {
        case .llamaCppHealth: object = ["status": "ok"]
        case .llamaCppProps:
            object = ["model_path": "/models/fixture.gguf", "model_alias": alias, "total_slots": 1,
                "modalities": ["vision": false, "video": false, "audio": false],
                "is_sleeping": false, "cors_proxy_enabled": false,
                "chat_template": generated && mutation == "metadata" ? "changed" : "fixture"]
        case .llamaCppModels: object = ["object": "list", "data": [["id": alias, "object": "model"]]]
        case .llamaCppChat:
            generated = true
            var message: [String: Any] = ["role": "assistant", "content": mutation == "payload" ? "{\"items\":[],\"extra\":true}" : "{\"items\":[]}"]
            if mutation == "tool" { message["tool_calls"] = [] }
            if mutation == "reasoning" { message["reasoning_content"] = "secret" }
            let choice: [String: Any] = ["index": 0, "message": message, "finish_reason": "stop"]
            var response: [String: Any] = ["object": "chat.completion", "model": mutation == "model" ? "other" : alias,
                "choices": mutation == "choices" ? [choice, choice] : [choice]]
            if mutation == "extra" { response["unexpected"] = true }
            object = response
        default: throw LoopbackHTTPError.nonLoopbackResponse
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private actor ChangingLlamaProbe: LlamaCppProcessProbing {
    let before: LlamaCppProcessSnapshot
    let after: LlamaCppProcessSnapshot
    var calls = 0
    init(before: LlamaCppProcessSnapshot, after: LlamaCppProcessSnapshot) { self.before = before; self.after = after }
    func snapshot() async throws -> LlamaCppProcessSnapshot {
        calls += 1
        return calls <= 4 ? before : after
    }
}

private actor SlowLlamaHTTP: LoopbackHTTPPerforming {
    var endpoints: [ApprovedLoopbackEndpoint] = []
    func perform(_ endpoint: ApprovedLoopbackEndpoint, body: Data?, timeoutMilliseconds: Int) async throws -> Data {
        endpoints.append(endpoint)
        try await Task.sleep(for: .seconds(120))
        return Data()
    }
}

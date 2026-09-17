import Foundation
import LocalOCRModelCore
import LocalOCRModelBridgeProtocol
@testable import LocalOCRModelBridgeKit
import Testing

@Suite("Verified local llama.cpp adapter")
struct LlamaCppBridgeAdapterTests {
    @Test func commandOperationalErrorsDoNotClaimLocalityChanged() {
        let cases: [(LMStudioCLIProbeError, ModelBridgeWireErrorCode)] = [
            (.timedOut, .generationTimedOut), (.cancelled, .cancelled),
            (.outputTooLarge, .providerResponseInvalid), (.invalidOutput, .providerResponseInvalid),
            (.commandFailed, .providerUnavailable), (.missingExecutable, .providerUnavailable),
            (.unsafeExecutable, .localityBlocked)
        ]
        for (error, expected) in cases {
            #expect(LlamaCppBridgeAdapter.errorCode(error) == expected, "error: \(error)")
        }
    }

    private let approvedGPTOSSFingerprint = "582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d"
    private let approvedGPTOSSAlias = "gpt-oss-120b-mxfp4"
    private let snapshot = LlamaCppProcessSnapshot(
        alias: "fixture", modelPath: "/models/fixture.gguf", fingerprint: String(repeating: "a", count: 64),
        harnessVersion: "llama-server:test", executablePath: "/usr/local/bin/llama-server",
        executableSHA256: String(repeating: "b", count: 64), modelSize: 10,
        modelModifiedNanoseconds: 1, executableSize: 20, executableModifiedNanoseconds: 2,
        processID: 100
    )

    private var approvedGPTOSSSnapshot: LlamaCppProcessSnapshot {
        LlamaCppProcessSnapshot(
            alias: approvedGPTOSSAlias, modelPath: snapshot.modelPath,
            fingerprint: approvedGPTOSSFingerprint, harnessVersion: snapshot.harnessVersion,
            executablePath: snapshot.executablePath, executableSHA256: snapshot.executableSHA256,
            modelSize: snapshot.modelSize, modelModifiedNanoseconds: snapshot.modelModifiedNanoseconds,
            executableSize: snapshot.executableSize, executableModifiedNanoseconds: snapshot.executableModifiedNanoseconds,
            processID: snapshot.processID
        )
    }

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
        #expect(object["max_tokens"] as? Int == 1024)
        #expect(object["reasoning_format"] as? String == "auto")
        #expect((object["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
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

    @Test func acceptsAndDiscardsBoundedReasoningOnlyForAttestedGPTOSS() async throws {
        let http = LlamaHTTP(alias: approvedGPTOSSAlias, mutation: "gpt_reasoning")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: approvedGPTOSSSnapshot))
        let identity = try #require(try await adapter.discover().first?.identity)

        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))

        #expect(response.error == nil)
        #expect(response.payloadJSON == "{\"items\":[]}")
        #expect(response.identity == identity)
    }

    @Test func acceptsAttestedGPTOSSReasoningAtTheExactMultibyteUTF8Limit() async throws {
        let exactLimit = String(repeating: "€", count: 21_845) + "x"
        #expect(exactLimit.utf8.count == 65_536)
        #expect(exactLimit.count == 21_846)
        let http = LlamaHTTP(alias: approvedGPTOSSAlias, mutation: "gpt_reasoning_multibyte_at_limit")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: approvedGPTOSSSnapshot))
        let identity = try #require(try await adapter.discover().first?.identity)

        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))

        #expect(response.error == nil)
        #expect(response.payloadJSON == "{\"items\":[]}")
    }

    @Test func rejectsAttestedGPTOSSReasoningOneMultibyteUTF8ByteOverTheLimit() async throws {
        let oneByteOver = String(repeating: "€", count: 21_845) + "xx"
        #expect(oneByteOver.utf8.count == 65_537)
        #expect(oneByteOver.count == 21_847)
        let http = LlamaHTTP(alias: approvedGPTOSSAlias, mutation: "gpt_reasoning_multibyte_one_byte_over")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: approvedGPTOSSSnapshot))
        let identity = try #require(try await adapter.discover().first?.identity)

        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))

        #expect(response.error?.code == .schemaFailure)
        #expect(response.payloadJSON == nil)
    }

    @Test func attestedGPTOSSStillRejectsMalformedReasoningAndResponses() async throws {
        for mutation in [
            "gpt_reasoning_not_string", "gpt_reasoning_too_long", "gpt_finish_missing", "gpt_finish_non_stop",
            "gpt_message_extra", "gpt_tool", "gpt_choices", "gpt_model", "gpt_think", "gpt_invalid_json", "gpt_payload"
        ] {
            let http = LlamaHTTP(alias: approvedGPTOSSAlias, mutation: mutation)
            let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: approvedGPTOSSSnapshot))
            let identity = try #require(try await adapter.discover().first?.identity)

            let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
                operation: .summarize, prompt: "Page 1: Fixture."))

            #expect(response.error?.code == .schemaFailure, "mutation: \(mutation)")
            #expect(response.payloadJSON == nil, "mutation: \(mutation)")
        }
    }

    @Test func rejectsReasoningForApprovedGPTOSSFingerprintUnderAnyOtherAlias() async throws {
        let wrongAliasSnapshot = LlamaCppProcessSnapshot(
            alias: "gpt-oss-120b-mxfp4-copy", modelPath: approvedGPTOSSSnapshot.modelPath,
            fingerprint: approvedGPTOSSFingerprint, harnessVersion: approvedGPTOSSSnapshot.harnessVersion,
            executablePath: approvedGPTOSSSnapshot.executablePath,
            executableSHA256: approvedGPTOSSSnapshot.executableSHA256,
            modelSize: approvedGPTOSSSnapshot.modelSize,
            modelModifiedNanoseconds: approvedGPTOSSSnapshot.modelModifiedNanoseconds,
            executableSize: approvedGPTOSSSnapshot.executableSize,
            executableModifiedNanoseconds: approvedGPTOSSSnapshot.executableModifiedNanoseconds,
            processID: approvedGPTOSSSnapshot.processID
        )
        let http = LlamaHTTP(alias: wrongAliasSnapshot.alias, mutation: "gpt_reasoning")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: wrongAliasSnapshot))
        let identity = try #require(try await adapter.discover().first?.identity)

        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))

        #expect(response.error?.code == .schemaFailure)
        #expect(response.payloadJSON == nil)
    }

    @Test func rejectsReasoningForApprovedGPTOSSAliasWithAnyOtherFingerprint() async throws {
        let wrongFingerprintSnapshot = LlamaCppProcessSnapshot(
            alias: approvedGPTOSSAlias, modelPath: snapshot.modelPath,
            fingerprint: snapshot.fingerprint, harnessVersion: snapshot.harnessVersion,
            executablePath: snapshot.executablePath,
            executableSHA256: snapshot.executableSHA256,
            modelSize: snapshot.modelSize,
            modelModifiedNanoseconds: snapshot.modelModifiedNanoseconds,
            executableSize: snapshot.executableSize,
            executableModifiedNanoseconds: snapshot.executableModifiedNanoseconds,
            processID: snapshot.processID
        )
        let http = LlamaHTTP(alias: approvedGPTOSSAlias, mutation: "gpt_reasoning")
        let adapter = LlamaCppBridgeAdapter(http: http, probe: LlamaProbe(snapshot: wrongFingerprintSnapshot))
        let identity = try #require(try await adapter.discover().first?.identity)

        let response = await adapter.generate(.generate(id: 1, expectedIdentity: identity,
            operation: .summarize, prompt: "Page 1: Fixture."))

        #expect(response.error?.code == .schemaFailure)
        #expect(response.payloadJSON == nil)
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

    @Test func changedGPTOSSIdentityAfterGenerationDiscardsOutput() async throws {
        let changed = LlamaCppProcessSnapshot(alias: approvedGPTOSSSnapshot.alias, modelPath: approvedGPTOSSSnapshot.modelPath,
            fingerprint: approvedGPTOSSSnapshot.fingerprint, harnessVersion: approvedGPTOSSSnapshot.harnessVersion,
            executablePath: approvedGPTOSSSnapshot.executablePath, executableSHA256: approvedGPTOSSSnapshot.executableSHA256,
            modelSize: approvedGPTOSSSnapshot.modelSize, modelModifiedNanoseconds: approvedGPTOSSSnapshot.modelModifiedNanoseconds,
            executableSize: approvedGPTOSSSnapshot.executableSize, executableModifiedNanoseconds: approvedGPTOSSSnapshot.executableModifiedNanoseconds,
            processID: approvedGPTOSSSnapshot.processID + 1)
        let adapter = LlamaCppBridgeAdapter(http: LlamaHTTP(alias: approvedGPTOSSAlias, mutation: "gpt_reasoning"),
            probe: ChangingLlamaProbe(before: approvedGPTOSSSnapshot, after: changed))
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
            let isGPTMutation = mutation.hasPrefix("gpt_")
            var message: [String: Any] = ["role": "assistant", "content": mutation == "payload" || mutation == "gpt_payload" ? "{\"items\":[],\"extra\":true}" : "{\"items\":[]}"]
            if mutation == "tool" { message["tool_calls"] = [] }
            if mutation == "reasoning" { message["reasoning_content"] = "secret" }
            if isGPTMutation { message["reasoning_content"] = "private reasoning" }
            if mutation == "gpt_reasoning_not_string" { message["reasoning_content"] = 1 }
            if mutation == "gpt_reasoning_too_long" { message["reasoning_content"] = String(repeating: "x", count: 65_537) }
            if mutation == "gpt_reasoning_multibyte_at_limit" { message["reasoning_content"] = String(repeating: "€", count: 21_845) + "x" }
            if mutation == "gpt_reasoning_multibyte_one_byte_over" { message["reasoning_content"] = String(repeating: "€", count: 21_845) + "xx" }
            if mutation == "message_extra" || mutation == "gpt_message_extra" { message["refusal"] = NSNull() }
            if mutation == "think" || mutation == "gpt_think" { message["content"] = "{\"items\":[{\"text\":\"<think>private reasoning</think>\",\"page\":1,\"evidence\":\"Fixture\"}]}" }
            if mutation == "invalid_json" || mutation == "gpt_invalid_json" { message["content"] = "{\"items\":[}" }
            if mutation == "gpt_tool" { message["tool_calls"] = [] }
            var choice: [String: Any] = ["index": 0, "message": message, "finish_reason": mutation == "finish_non_stop" || mutation == "gpt_finish_non_stop" ? "length" : "stop"]
            if mutation == "finish_missing" || mutation == "gpt_finish_missing" { choice.removeValue(forKey: "finish_reason") }
            var response: [String: Any] = ["object": "chat.completion", "model": mutation == "model" || mutation == "gpt_model" ? "other" : alias,
                "choices": mutation == "choices" || mutation == "gpt_choices" ? [choice, choice] : [choice]]
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

import Foundation
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite("Model bridge messages")
struct ModelBridgeMessagesTests {
    @Test
    func discoveryRequestRoundTripsWithNoDocumentContent() throws {
        let request = ModelBridgeRequest.discover(id: 7, provider: .ollama)

        let data = try JSONEncoder().encode(request)

        #expect(!String(decoding: data, as: UTF8.self).contains("document"))
        #expect(try JSONDecoder().decode(ModelBridgeRequest.self, from: data) == request)
    }

    @Test
    func requestDecoderRejectsUnknownKeys() throws {
        var object = validDiscoveryObject()
        object["document"] = "must not cross discovery"

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsUnsupportedVersion() throws {
        var object = validDiscoveryObject()
        object["version"] = 2

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test(arguments: ["apple_foundation_models", "remote_provider"])
    func requestDecoderRejectsUnsupportedProviders(_ provider: String) throws {
        var object = validDiscoveryObject()
        object["provider"] = provider

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsUnsupportedAction() throws {
        var object = validDiscoveryObject()
        object["action"] = "delete"

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsMoreThanSixtyFourFields() throws {
        var object = validGenerateObject()
        object["fields"] = (0..<65).map { "field-\($0)" }

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsEmptyModelIdentifier() throws {
        var object = validGenerateObject()
        object["model"] = "   "

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsPromptOverOneMillionUTF8Bytes() throws {
        var object = validGenerateObject()
        object["prompt"] = String(repeating: "a", count: 1_000_001)

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test(arguments: [999, 120_001])
    func requestDecoderRejectsTimeoutOutsideClosedRange(_ timeout: Int) throws {
        var object = validDiscoveryObject()
        object["timeoutMilliseconds"] = timeout

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsDiscoveryPrompt() throws {
        var object = validDiscoveryObject()
        object["prompt"] = "document text"

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsDiscoveryModelAndFields() throws {
        var object = validDiscoveryObject()
        object["model"] = "gemma4:8b"
        object["fields"] = ["summary"]

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func requestDecoderRejectsGenerateWithoutRequiredValues() throws {
        var object = validGenerateObject()
        object.removeValue(forKey: "model")
        object.removeValue(forKey: "operation")
        object.removeValue(forKey: "prompt")

        #expect(throws: (any Error).self) {
            try decodeRequest(object)
        }
    }

    @Test
    func responseRoundTripsCandidateAndPayload() throws {
        let identity = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:abc",
            harnessVersion: "0.13.0"
        )
        let response = ModelBridgeResponse(
            id: 17,
            candidates: [
                BridgeModelCandidate(
                    identity: identity,
                    displayName: "Gemma 4 8B",
                    locality: .verifiedLocal,
                    localityReason: "Local model files verified."
                )
            ],
            payloadJSON: "{\"summary\":\"ok\"}",
            identity: identity
        )

        let data = try JSONEncoder().encode(response)

        #expect(try JSONDecoder().decode(ModelBridgeResponse.self, from: data) == response)
    }

    @Test
    func responseDecoderRejectsUnknownKeys() throws {
        let object: [String: Any] = [
            "version": 1,
            "id": 7,
            "candidates": [],
            "unexpected": true
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelBridgeResponse.self, from: data)
        }
    }

    @Test
    func responseDecoderRejectsUnsupportedVersion() throws {
        let object: [String: Any] = [
            "version": 2,
            "id": 7,
            "candidates": []
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelBridgeResponse.self, from: data)
        }
    }
}

private func validDiscoveryObject() -> [String: Any] {
    [
        "version": 1,
        "id": 7,
        "action": "discover",
        "provider": "ollama",
        "fields": [],
        "timeoutMilliseconds": 10_000
    ]
}

private func validGenerateObject() -> [String: Any] {
    [
        "version": 1,
        "id": 8,
        "action": "generate",
        "provider": "ollama",
        "model": "gemma4:8b",
        "operation": "summarize",
        "prompt": "Summarize this OCR text.",
        "fields": [],
        "timeoutMilliseconds": 30_000
    ]
}

private func decodeRequest(_ object: [String: Any]) throws -> ModelBridgeRequest {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(ModelBridgeRequest.self, from: data)
}

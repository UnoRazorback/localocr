import Foundation
import LocalOCRModelBridgeKit
import LocalOCRModelBridgeProtocol
import Testing

@Suite("Model bridge server")
struct ModelBridgeServerTests {
    @Test
    func serverRejectsMessagesOverOneMiBBeforeDispatch() async {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)

        let result = await server.consume(
            Data(repeating: 65, count: 1_048_577) + Data([10])
        )

        #expect(result.error?.code == .messageTooLarge)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func serverDispatchesValidFrameAndCorrelatesHandlerResponse() async throws {
        let handler = WrongIDBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        var frame = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 42, provider: .ollama)
        )
        frame.append(10)

        let result = await server.consume(frame)

        #expect(result.id == 42)
        #expect(result.error == nil)
    }

    @Test
    func serverReturnsUnsupportedVersionWithParsedRequestID() async throws {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        let frame = try framedJSON([
            "version": 2,
            "id": 73,
            "action": "discover",
            "provider": "ollama",
            "fields": [],
            "timeoutMilliseconds": 10_000
        ])

        let result = await server.consume(frame)

        #expect(result.id == 73)
        #expect(result.error?.code == .unsupportedVersion)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func serverReturnsInvalidRequestWithParsedRequestID() async throws {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        let frame = try framedJSON([
            "version": 1,
            "id": 91,
            "action": "discover",
            "provider": "ollama",
            "fields": [],
            "timeoutMilliseconds": 10_000,
            "document": "forbidden"
        ])

        let result = await server.consume(frame)

        #expect(result.id == 91)
        #expect(result.error?.code == .invalidRequest)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func unimplementedHandlerReturnsStableProviderError() async {
        let response = await UnimplementedModelBridgeHandler().handle(
            .discover(id: 5, provider: .lmStudio)
        )

        #expect(response.id == 5)
        #expect(response.error?.code == .providerNotImplemented)
        #expect(response.error?.message == "Provider adapter is not implemented.")
    }

    @Test
    func runWritesOneJSONResponsePerRequestAndNoDiagnostics() async throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())
        let first = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 11, provider: .ollama)
        )
        let second = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 12, provider: .lmStudio)
        )
        try input.fileHandleForWriting.write(contentsOf: first + Data([10]) + second + Data([10]))
        try input.fileHandleForWriting.close()

        await server.run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        let outputData = try #require(try output.fileHandleForReading.readToEnd())
        let lines = outputData.split(separator: 10)
        let responses = try lines.map {
            try JSONDecoder().decode(ModelBridgeResponse.self, from: Data($0))
        }
        #expect(responses.map(\.id) == [11, 12])
        #expect(responses.allSatisfy { $0.error?.code == .providerNotImplemented })
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }

    @Test
    func runExitsCleanlyOnImmediateEOF() async throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())
        try input.fileHandleForWriting.close()

        await server.run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        #expect((try output.fileHandleForReading.readToEnd()) ?? Data() == Data())
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }
}

private actor RecordingBridgeHandler: ModelBridgeHandling {
    private(set) var requestCount = 0

    func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse {
        requestCount += 1
        return ModelBridgeResponse(id: request.id)
    }
}

private actor WrongIDBridgeHandler: ModelBridgeHandling {
    func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse {
        ModelBridgeResponse(id: 999)
    }
}

private func framedJSON(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
}

import Foundation
import LocalOCRService
import MCP
import Testing

@testable import LocalOCRMCP

@Test func serverRunnerRegistersCatalogAndForwardsToolCallsExactlyOnce() async throws {
    let forwardedResult = CallTool.Result(
        content: [.text(text: "forwarded", annotations: nil, _meta: nil)],
        isError: false
    )
    let dispatcher = RecordingToolDispatcher(result: forwardedResult)
    let runner = MCPServerRunner(dispatcher: dispatcher)
    let transports = await InMemoryTransport.createConnectedPair()
    let server = await runner.makeServer()
    let client = Client(name: "runner-tests", version: "1.0.0")

    try await server.start(transport: transports.server)
    let initialization = try await client.connect(transport: transports.client)
    let listedTools = try await client.listTools()
    let arguments: [String: Value] = [
        "file_path": "fixture.pdf",
        "dpi": 300,
    ]
    let callResult: (content: [Tool.Content], isError: Bool?) = try await client.callTool(
        name: "ocr_pdf",
        arguments: arguments
    )

    #expect(initialization.serverInfo.name == "localocr")
    #expect(initialization.serverInfo.version == "0.2.0")
    #expect(listedTools.tools == MCPToolCatalog.tools)
    #expect(callResult.content == forwardedResult.content)
    #expect(callResult.isError == false)
    #expect(
        await dispatcher.recordedCalls() == [
            .init(name: "ocr_pdf", arguments: arguments),
        ]
    )

    await client.disconnect()
    await server.stop()
}

@Test func serverRunnerReturnsStableToolErrorWhenBatchHandlerIsCancelled() async throws {
    let service = MCPBatchCancellationService()
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let runner = MCPServerRunner(dispatcher: dispatcher)
    let transports = await InMemoryTransport.createConnectedPair()
    let server = await runner.makeServer()
    let client = Client(name: "runner-tests", version: "1.0.0")

    try await server.start(transport: transports.server)
    _ = try await client.connect(transport: transports.client)
    let context: RequestContext<CallTool.Result> = try await client.callTool(
        name: "ocr_pdf_batch",
        arguments: ["file_paths": ["/input.pdf"]]
    )
    await service.waitUntilStarted()
    try await client.notify(
        CancelledNotification.message(
            .init(requestId: context.requestID, reason: "test cancellation")
        )
    )
    let result = try await context.value
    let expected = #"{"error":{"code":"cancelled","message":"Operation cancelled"}}"#
    let expectedValue = try JSONDecoder().decode(Value.self, from: Data(expected.utf8))

    #expect(try runnerResultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == true)

    await client.disconnect()
    await server.stop()
}

private func runnerResultText(_ result: CallTool.Result) throws -> String {
    let content = try #require(result.content.first)
    guard case let .text(text, _, _) = content else {
        throw MCPServerRunnerTestError.unexpectedContent
    }
    return text
}

private enum MCPServerRunnerTestError: Error {
    case unexpectedContent
}

private actor RecordingToolDispatcher: MCPToolDispatching {
    struct Invocation: Equatable, Sendable {
        let name: String
        let arguments: [String: Value]
    }

    private let result: CallTool.Result
    private var calls: [Invocation] = []

    init(result: CallTool.Result) {
        self.result = result
    }

    func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
        calls.append(.init(name: name, arguments: arguments))
        return result
    }

    func recordedCalls() -> [Invocation] {
        calls
    }
}

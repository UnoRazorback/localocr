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

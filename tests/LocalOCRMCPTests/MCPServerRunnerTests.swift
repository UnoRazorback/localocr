import MCP
@testable import LocalOCRMCP
import Testing

@Suite struct MCPServerRunnerTests {
    @Test func runnerListsTheCatalogAndForwardsOneToolCallUnchanged() async throws {
        let dispatcher = RecordingDispatcher()
        let runner = MCPServerRunner(dispatcher: dispatcher)
        let server = await runner.makeServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "runner-test-client", version: "1.0.0")

        try await server.start(transport: serverTransport)
        let initialization = try await client.connect(transport: clientTransport)
        #expect(initialization.serverInfo.name == "localocr")
        #expect(initialization.serverInfo.version == "0.3.0")

        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name).sorted() == MCPToolCatalog.tools.map(\.name).sorted())

        let result = try await client.callTool(
            name: "inspect_pdf",
            arguments: ["file_path": "/tmp/contract.pdf"]
        )

        #expect(result.isError == nil)
        #expect(await dispatcher.calls() == [
            ToolCall(name: "inspect_pdf", arguments: ["file_path": "/tmp/contract.pdf"])
        ])

        await client.disconnect()
        await server.stop()
    }

    @Test func runnerUsesOnlyTheExplicitlyInjectedTransport() async throws {
        let dispatcher = RecordingDispatcher()
        let runner = MCPServerRunner(dispatcher: dispatcher)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "runner-transport-test-client", version: "1.0.0")
        let runnerTask = Task {
            try await runner.run(transport: serverTransport)
        }

        _ = try await client.connect(transport: clientTransport)
        let (tools, _) = try await client.listTools()
        #expect(tools.count == 9)

        await client.disconnect()
        try await runnerTask.value
    }
}

private struct ToolCall: Sendable, Equatable {
    let name: String
    let arguments: [String: Value]?
}

private actor RecordingDispatcher: MCPToolDispatching {
    private var recordedCalls: [ToolCall] = []

    func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        recordedCalls.append(ToolCall(name: name, arguments: arguments))
        return CallTool.Result(content: [.text(text: "recorded", annotations: nil, _meta: nil)])
    }

    func calls() -> [ToolCall] {
        recordedCalls
    }
}

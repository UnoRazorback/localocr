import Foundation
import Logging
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

    @Test func cancellingRunnerStopsServerAndDisconnectsAnOpenClientPromptly() async throws {
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "runner-cancellation-test-client", version: "1.0.0")
        let runnerTask = Task {
            try await runner.run(transport: serverTransport)
        }

        _ = try await client.connect(transport: clientTransport)
        _ = try await client.listTools()

        let safetyDisconnect = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
            await client.disconnect()
            return true
        }

        runnerTask.cancel()
        let result = await runnerTask.result
        safetyDisconnect.cancel()

        #expect(await safetyDisconnect.value == false)
        switch result {
        case .success:
            Issue.record("A cancelled runner must finish with CancellationError")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        await #expect(throws: (any Error).self) {
            _ = try await client.listTools()
        }
    }

    @Test func runnerPreservesStartErrorAndDisconnectsTransport() async {
        let transport = FailingStartTransport()
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())

        await #expect(throws: RunnerProbeError.startFailed) {
            try await runner.run(transport: transport)
        }
        #expect(await transport.disconnectCount() == 1)
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

private enum RunnerProbeError: Error, Equatable {
    case startFailed
}

private actor FailingStartTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.failing-start")
    private var recordedDisconnectCount = 0

    func connect() async throws {
        throw RunnerProbeError.startFailed
    }

    func disconnect() async {
        recordedDisconnectCount += 1
    }

    func send(_ data: Data) async throws {
        throw RunnerProbeError.startFailed
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func disconnectCount() -> Int {
        recordedDisconnectCount
    }
}

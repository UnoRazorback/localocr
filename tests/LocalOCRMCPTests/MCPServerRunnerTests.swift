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

    @Test func cancellationBeforeServerTransportRegistrationIsLatchedBeforeConnect() async {
        let startBarrier = SuspendingStartBarrier()
        let cancellationCleanup = OneShotEvent()
        let transport = CountingTransport()
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let runnerTask = Task {
            try await runner.run(
                transport: transport,
                beforeStart: {
                    await startBarrier.suspend()
                },
                cancellationCleanupDidRun: {
                    await cancellationCleanup.signal()
                }
            )
        }

        await startBarrier.waitUntilSuspended()
        runnerTask.cancel()
        await cancellationCleanup.wait()
        await startBarrier.resume()

        let result = await runnerTask.result
        #expect(await transport.connectCount() == 0)
        #expect(await transport.disconnectCount() == 1)
        switch result {
        case .success:
            Issue.record("A cancelled runner must finish with CancellationError")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    @Test func cancellationAndCatchShareOneStopWhileDisconnectSuspends() async throws {
        let transport = SuspendingDisconnectTransport()
        let stopper = CountingServerStopper()
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let runnerTask = Task {
            try await runner.run(
                transport: transport,
                stopServer: { server in
                    await stopper.stop(server)
                }
            )
        }

        await transport.waitUntilConnected()
        runnerTask.cancel()
        await transport.waitUntilFirstDisconnectStarts()
        await Task.yield()
        await Task.yield()
        await transport.resumeFirstDisconnect()

        let result = await runnerTask.result
        #expect(await stopper.stopCount() == 1)
        #expect(await transport.disconnectCount() == 1)
        switch result {
        case .success:
            Issue.record("A cancelled runner must finish with CancellationError")
        case let .failure(error):
            #expect(error is CancellationError)
        }
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

private actor OneShotEvent {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let currentWaiters = waiters
        waiters = []
        currentWaiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor SuspendingStartBarrier {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CountingTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.counting")
    private var recordedConnectCount = 0
    private var recordedDisconnectCount = 0

    func connect() {
        recordedConnectCount += 1
    }

    func disconnect() {
        recordedDisconnectCount += 1
    }

    func send(_ data: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func connectCount() -> Int {
        recordedConnectCount
    }

    func disconnectCount() -> Int {
        recordedDisconnectCount
    }
}

private actor SuspendingDisconnectTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.suspending-disconnect")
    private var isConnected = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedDisconnectCount = 0
    private var firstDisconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDisconnectContinuation: CheckedContinuation<Void, Never>?

    func connect() {
        isConnected = true
        let waiters = connectionWaiters
        connectionWaiters = []
        waiters.forEach { $0.resume() }
    }

    func disconnect() async {
        recordedDisconnectCount += 1
        guard recordedDisconnectCount == 1 else { return }

        let waiters = firstDisconnectWaiters
        firstDisconnectWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstDisconnectContinuation = continuation
        }
    }

    func send(_ data: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { _ in }
    }

    func waitUntilConnected() async {
        guard !isConnected else { return }
        await withCheckedContinuation { continuation in
            connectionWaiters.append(continuation)
        }
    }

    func waitUntilFirstDisconnectStarts() async {
        guard recordedDisconnectCount > 0 else {
            await withCheckedContinuation { continuation in
                firstDisconnectWaiters.append(continuation)
            }
            return
        }
    }

    func resumeFirstDisconnect() {
        firstDisconnectContinuation?.resume()
        firstDisconnectContinuation = nil
    }

    func disconnectCount() -> Int {
        recordedDisconnectCount
    }
}

private actor CountingServerStopper {
    private var recordedStopCount = 0

    func stop(_ server: Server) async {
        recordedStopCount += 1
        await server.stop()
    }

    func stopCount() -> Int {
        recordedStopCount
    }
}

import Foundation
import Logging
import MCPStdio
@testable import LocalOCRMCP
import Testing

@Suite struct MCPServerRunnerTests {
    @Test func runnerListsTheCatalogAndForwardsOneToolCallUnchanged() async throws {
        let dispatcher = RecordingDispatcher()
        let runner = MCPServerRunner(dispatcher: dispatcher)
        let server = await runner.makeServer()
        let transport = RunnerTestTransport()

        try await server.start(transport: transport)
        let initialization = try await initialize(transport)
        #expect(initialization.serverInfo.name == "localocr")
        #expect(initialization.serverInfo.version == "0.3.0")

        let listResponse = try await exchange(
            ListTools.request(id: 2, .init()),
            response: Response<ListTools>.self,
            through: transport
        )
        let tools = try listResponse.result.get().tools
        #expect(tools.map { $0.name }.sorted() == MCPToolCatalog.tools.map { $0.name }.sorted())

        let callResponse = try await exchange(
            CallTool.request(
                id: 3,
                .init(name: "inspect_pdf", arguments: ["file_path": "/tmp/contract.pdf"])
            ),
            response: Response<CallTool>.self,
            through: transport
        )
        let result = try callResponse.result.get()

        #expect(result.isError == nil)
        #expect(await dispatcher.calls() == [
            ToolCall(name: "inspect_pdf", arguments: ["file_path": "/tmp/contract.pdf"])
        ])

        await server.stop()
    }

    @Test func runnerUsesOnlyTheExplicitlyInjectedTransport() async throws {
        let dispatcher = RecordingDispatcher()
        let runner = MCPServerRunner(dispatcher: dispatcher)
        let transport = RunnerTestTransport()
        let runnerTask = Task {
            try await runner.run(transport: transport)
        }

        _ = try await initialize(transport)
        let response = try await exchange(
            ListTools.request(id: 2, .init()),
            response: Response<ListTools>.self,
            through: transport
        )
        #expect(try response.result.get().tools.count == 9)

        await transport.finishInput()
        try await runnerTask.value
    }

    @Test func cancellingRunnerStopsServerAndDisconnectsAnOpenClientPromptly() async throws {
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let transport = RunnerTestTransport()
        let runnerTask = Task {
            try await runner.run(transport: transport)
        }

        _ = try await initialize(transport)
        _ = try await exchange(
            ListTools.request(id: 2, .init()),
            response: Response<ListTools>.self,
            through: transport
        )

        let safetyDisconnect = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
            await transport.finishInput()
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
        #expect(await transport.waitUntilDisconnected())
        await #expect(throws: (any Error).self) {
            try await transport.push(JSONEncoder().encode(ListTools.request(id: 3, .init())))
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

    @Test func cancellationDuringSuspendedConnectWaitsToDisconnectTheOpenedTransportOnce() async {
        let cancellationCleanup = OneShotEvent()
        let transport = SuspendingConnectTransport()
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let runnerTask = Task {
            try await runner.run(
                transport: transport,
                cancellationCleanupDidRun: {
                    await cancellationCleanup.signal()
                }
            )
        }

        await transport.waitUntilConnectIsSuspended()
        runnerTask.cancel()
        await cancellationCleanup.wait()

        #expect(await transport.disconnectStartedWhileConnecting(within: .milliseconds(250)) == false)
        await transport.resumeConnect()

        let result = await runnerTask.result
        #expect(await transport.connectCount() == 1)
        #expect(await transport.disconnectCount() == 1)
        #expect(await transport.isConnected() == false)
        switch result {
        case .success:
            Issue.record("A cancelled runner must finish with CancellationError")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    @Test func productionRunnerTerminatesWhenItsEightFrameAdapterDropsFloodedInput() async {
        let transport = FloodingBackpressureTransport(frameCount: 64)
        let runner = MCPServerRunner(dispatcher: RecordingDispatcher())
        let runnerTask = Task {
            try await runner.run(transport: transport)
        }

        let disconnected = await transport.waitUntilDisconnected(within: .seconds(1))
        if !disconnected {
            await transport.forceRelease()
            runnerTask.cancel()
        }
        _ = await runnerTask.result

        #expect(disconnected)
        #expect(await transport.disconnectCount() == 1)
    }
}

private func initialize(_ transport: RunnerTestTransport) async throws -> Initialize.Result {
    await transport.waitUntilConnected()
    let response = try await exchange(
        Initialize.request(
            id: 1,
            .init(
                capabilities: .init(),
                clientInfo: .init(name: "runner-test-client", version: "1.0.0")
            )
        ),
        response: Response<Initialize>.self,
        through: transport
    )
    let result = try response.result.get()
    try await transport.push(JSONEncoder().encode(Message<InitializedNotification>(params: .init())))
    return result
}

private func exchange<M: MCPStdio.Method>(
    _ request: Request<M>,
    response: Response<M>.Type,
    through transport: RunnerTestTransport
) async throws -> Response<M> {
    try await transport.push(JSONEncoder().encode(request))
    return try JSONDecoder().decode(response, from: await transport.nextOutput())
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
    case disconnected
}

private actor RunnerTestTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.raw-json")
    private let input: AsyncThrowingStream<Data, any Error>
    private let inputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var connected = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var outputs: [Data] = []
    private var nextOutputIndex = 0
    private var outputWaiters: [CheckedContinuation<Data, Never>] = []

    init() {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        input = AsyncThrowingStream { continuation = $0 }
        inputContinuation = continuation
    }

    func connect() async throws {
        connected = true
        let waiters = connectionWaiters
        connectionWaiters = []
        waiters.forEach { $0.resume() }
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        inputContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw RunnerProbeError.disconnected }
        outputs.append(data)
        if !outputWaiters.isEmpty {
            outputWaiters.removeFirst().resume(returning: data)
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        input
    }

    func push(_ data: Data) throws {
        guard connected else { throw RunnerProbeError.disconnected }
        inputContinuation.yield(data)
    }

    func finishInput() {
        inputContinuation.finish()
    }

    func nextOutput() async -> Data {
        if nextOutputIndex < outputs.count {
            defer { nextOutputIndex += 1 }
            return outputs[nextOutputIndex]
        }
        let output = await withCheckedContinuation { outputWaiters.append($0) }
        nextOutputIndex += 1
        return output
    }

    func waitUntilDisconnected() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while connected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !connected
    }

    func waitUntilConnected() async {
        guard !connected else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }
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

private actor SuspendingConnectTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.suspending-connect")
    private var recordedConnectCount = 0
    private var recordedDisconnectCount = 0
    private var connecting = false
    private var connected = false
    private var connectSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectContinuation: CheckedContinuation<Void, Never>?

    func connect() async {
        recordedConnectCount += 1
        connecting = true
        let waiters = connectSuspensionWaiters
        connectSuspensionWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { connectContinuation = $0 }
        connecting = false
        connected = true
    }

    func disconnect() {
        recordedDisconnectCount += 1
        connected = false
    }

    func send(_ data: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { _ in }
    }

    func waitUntilConnectIsSuspended() async {
        guard !connecting else { return }
        await withCheckedContinuation { connectSuspensionWaiters.append($0) }
    }

    func disconnectStartedWhileConnecting(within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while recordedDisconnectCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return connecting && recordedDisconnectCount > 0
    }

    func resumeConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func connectCount() -> Int { recordedConnectCount }
    func disconnectCount() -> Int { recordedDisconnectCount }
    func isConnected() -> Bool { connected }
}

private actor FloodingBackpressureTransport: Transport {
    nonisolated let logger = Logger(label: "localocr.runner-tests.flooding-backpressure")
    private let input: AsyncThrowingStream<Data, any Error>
    private var connected = false
    private var recordedDisconnectCount = 0
    private var sendContinuation: CheckedContinuation<Void, any Error>?

    init(frameCount: Int) {
        let request = try! JSONEncoder().encode(ListTools.request(id: 1, .init()))
        input = AsyncThrowingStream { continuation in
            for _ in 0..<frameCount {
                continuation.yield(request)
            }
        }
    }

    func connect() {
        connected = true
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        recordedDisconnectCount += 1
        sendContinuation?.resume(throwing: RunnerProbeError.disconnected)
        sendContinuation = nil
    }

    func send(_ data: Data) async throws {
        _ = data
        guard connected else { throw RunnerProbeError.disconnected }
        try await withCheckedThrowingContinuation { continuation in
            sendContinuation = continuation
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        input
    }

    func waitUntilDisconnected(within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while connected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !connected
    }

    func forceRelease() {
        sendContinuation?.resume(throwing: RunnerProbeError.disconnected)
        sendContinuation = nil
        connected = false
    }

    func disconnectCount() -> Int { recordedDisconnectCount }
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

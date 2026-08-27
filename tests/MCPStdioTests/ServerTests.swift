import Foundation
import Logging
import MCPStdio
import Testing

@Suite("Server lifecycle and dispatch")
struct ServerTests {
    @Test
    func initializeNegotiatesVersionAndRequiresInitializedBeforeRequests() async throws {
        let harness = await ServerHarness.make()
        try await harness.start()

        await harness.send(request(id: 1, method: Ping.name))
        #expect(try await harness.nextResponse() == .error(id: 1, code: -32600))

        await harness.send(initializeRequest(id: 2, version: "2025-03-26"))
        let initialized = try await harness.nextResponse()
        #expect(initialized.id == 2)
        #expect(initialized.errorCode == nil)
        #expect(initialized.result?["protocolVersion"] == "2025-03-26")
        #expect(initialized.result?["serverInfo"]?["name"] == "fixture-server")
        #expect(initialized.result?["serverInfo"]?["version"] == "1.2.3")

        await harness.send(request(id: 3, method: Ping.name))
        #expect(try await harness.nextResponse() == .error(id: 3, code: -32600))

        await harness.send(notification(method: InitializedNotification.name))
        await harness.send(request(id: 4, method: Ping.name))
        #expect(try await harness.nextResponse() == .success(id: 4, result: [:]))
    }

    @Test
    func listAndCallToolsUseRegisteredTypedHandlers() async throws {
        let calls = ToolCallRecorder()
        let harness = await ServerHarness.make(calls: calls)
        try await harness.startAndInitialize()

        await harness.send(request(id: "list", method: ListTools.name))
        let list = try await harness.nextResponse()
        #expect(list.id == "list")
        #expect(list.result?["tools"]?[0]?["name"] == "fixture")

        await harness.send(request(
            id: "call",
            method: CallTool.name,
            params: ["name": "fixture", "arguments": ["value": 42]]
        ))
        let call = try await harness.nextResponse()
        #expect(call.id == "call")
        #expect(call.result?["content"]?[0]?["text"] == "fixture:42")
        #expect(await calls.names == ["fixture"])
    }

    @Test
    func unknownMethodReturnsMethodNotFoundWithoutCallingTools() async throws {
        let calls = ToolCallRecorder()
        let harness = await ServerHarness.make(calls: calls)
        try await harness.startAndInitialize()

        await harness.send(request(id: 7, method: "files/delete", params: [:]))

        #expect(try await harness.nextResponse() == .error(id: 7, code: -32601))
        #expect(await calls.names.isEmpty)
    }

    @Test
    func malformedJSONAndStructurallyInvalidRequestsUseStandardErrors() async throws {
        let harness = await ServerHarness.make()
        try await harness.startAndInitialize()

        await harness.send(Data([0xff, 0xfe]))
        #expect(try await harness.nextResponse() == .error(id: nil, code: -32700))

        await harness.send(Data(#"{"jsonrpc":"2.0","id":8,"params":{}}"#.utf8))
        #expect(try await harness.nextResponse() == .error(id: 8, code: -32600))

        await harness.send(Data(#"{"jsonrpc":"2.0","params":{}}"#.utf8))
        #expect(try await harness.nextResponseIfAvailable() == .error(id: nil, code: -32600))

        await harness.send(request(id: 9, method: CallTool.name, params: ["arguments": [:]]))
        #expect(try await harness.nextResponse() == .error(id: 9, code: -32602))
    }

    @Test
    func unsupportedAndMalformedNotificationsAreSilent() async throws {
        let harness = await ServerHarness.make()
        try await harness.startAndInitialize()
        let initialCount = await harness.outputCount

        await harness.send(notification(method: "notifications/unknown", params: ["secret": "must-stay-silent"]))
        await harness.send(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":17}"#.utf8))
        await harness.send(request(id: "barrier", method: Ping.name))
        #expect(try await harness.nextResponse().id == "barrier")

        #expect(await harness.outputCount == initialCount + 1)
    }

    @Test
    func eofCompletesAndDisconnectsTheTransport() async throws {
        let harness = await ServerHarness.make()
        try await harness.start()

        await harness.finishInput()
        await harness.waitUntilCompleted()

        #expect(await harness.disconnectCount == 1)
    }

    @Test
    func eofCancelsOutstandingWorkWithoutEmittingALateResponse() async throws {
        let gate = CallGate()
        let harness = await ServerHarness.make(gate: gate)
        try await harness.startAndInitialize()
        let outputCountBeforeRequest = await harness.outputCount

        await harness.send(request(id: 10, method: CallTool.name, params: ["name": "at-eof"]))
        await gate.waitUntilStarted("at-eof")
        await harness.finishInput()
        await harness.waitUntilCompleted()
        await gate.release("at-eof")
        await harness.drainScheduling()

        #expect(await harness.disconnectCount == 1)
        #expect(await harness.outputCount == outputCountBeforeRequest)
    }

    @Test
    func duplicateActiveIDIsRejectedWithoutReplacingOriginalRequest() async throws {
        let gate = CallGate()
        let harness = await ServerHarness.make(gate: gate)
        try await harness.startAndInitialize()

        await harness.send(request(id: 11, method: CallTool.name, params: ["name": "first"]))
        await gate.waitUntilStarted("first")
        await harness.send(request(id: 11, method: Ping.name))

        #expect(try await harness.nextResponse() == .error(id: 11, code: -32600))
        await gate.release("first")
        let original = try await harness.nextResponse()
        #expect(original.id == 11)
        #expect(original.errorCode == nil)
        #expect(original.result?["content"]?[0]?["text"] == "first")
    }

    @Test
    func distinctConcurrentRequestsRespondInCompletionOrderWithCorrelatedIDs() async throws {
        let gate = CallGate()
        let harness = await ServerHarness.make(gate: gate)
        try await harness.startAndInitialize()

        await harness.send(request(id: "slow-a", method: CallTool.name, params: ["name": "a"]))
        await harness.send(request(id: "slow-b", method: CallTool.name, params: ["name": "b"]))
        await gate.waitUntilStarted("a")
        await gate.waitUntilStarted("b")

        await gate.release("b")
        #expect(try await harness.nextResponse().id == "slow-b")
        await gate.release("a")
        #expect(try await harness.nextResponse().id == "slow-a")
    }

    @Test
    func cancellationBeforeWorkIsIgnoredAndDuringWorkProducesOneTerminalResponse() async throws {
        let gate = CallGate()
        let harness = await ServerHarness.make(gate: gate)
        try await harness.startAndInitialize()

        await harness.send(cancel(id: 20))
        await harness.send(request(id: 20, method: Ping.name))
        #expect(try await harness.nextResponse() == .success(id: 20, result: [:]))

        await harness.send(request(id: 21, method: CallTool.name, params: ["name": "cancel-me"]))
        await gate.waitUntilStarted("cancel-me")
        await harness.send(cancel(id: 21))
        await harness.send(cancel(id: 21))

        #expect(try await harness.nextResponse() == .error(id: 21, code: -32603))
        await gate.release("cancel-me")
        await harness.drainScheduling()
        #expect(await harness.responseCount(id: 21) == 1)
    }

    @Test
    func cancellationAfterCompletionAndRepeatedCancellationAreSilent() async throws {
        let harness = await ServerHarness.make()
        try await harness.startAndInitialize()

        await harness.send(request(id: 22, method: Ping.name))
        _ = try await harness.nextResponse()
        let completedCount = await harness.outputCount
        await harness.send(cancel(id: 22))
        await harness.send(cancel(id: 22))
        await harness.drainScheduling()

        #expect(await harness.outputCount == completedCount)
    }

    @Test
    func thrownHandlerReturnsInternalErrorWithoutPayloadInLogs() async throws {
        let logs = CapturedServerLogs()
        let harness = await ServerHarness.make(logs: logs, handlerFailure: "private-document-text")
        try await harness.startAndInitialize()

        await harness.send(request(id: 30, method: CallTool.name, params: ["name": "throw"]))

        #expect(try await harness.nextResponse() == .error(id: 30, code: -32603))
        #expect(logs.joined.contains("private-document-text") == false)
    }

    @Test
    func outputFailureStopsTheConnectionSafely() async throws {
        let harness = await ServerHarness.make()
        try await harness.startAndInitialize()
        await harness.failFutureWrites()

        await harness.send(request(id: 31, method: Ping.name))
        await harness.waitUntilCompleted()

        #expect(await harness.disconnectCount == 1)
    }

    @Test
    func responseEncodingFailureStopsTheConnectionSafely() async throws {
        let harness = await ServerHarness.make()
        try await harness.startAndInitialize()
        let outputCountBeforeRequest = await harness.outputCount

        await harness.send(request(id: 32, method: UnencodableMethod.name))

        let disconnected = await harness.waitUntilDisconnected()
        #expect(disconnected)
        guard disconnected else {
            await harness.stop()
            return
        }
        await harness.waitUntilCompleted()
        #expect(await harness.outputCount == outputCountBeforeRequest)
    }
}

private actor ServerHarness {
    private let server: Server
    private let transport: InMemoryTransport

    static func make(
        calls: ToolCallRecorder = .init(),
        gate: CallGate? = nil,
        logs: CapturedServerLogs = .init(),
        handlerFailure: String? = nil
    ) async -> ServerHarness {
        let logger = Logger(label: "server-tests") { _ in CapturingServerLogHandler(captured: logs) }
        let transport = InMemoryTransport(logger: logger)
        let server = Server(
            name: "fixture-server",
            version: "1.2.3",
            capabilities: .init(tools: .init()),
            configuration: .strict
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [.init(name: "fixture", description: "Fixture", inputSchema: ["type": "object"])])
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await calls.record(parameters.name)
            if let handlerFailure, parameters.name == "throw" {
                throw FixtureFailure(message: handlerFailure)
            }
            if let gate {
                await gate.begin(parameters.name)
            }
            let value = parameters.arguments?["value"]?.intValue
            let text = value.map { "\(parameters.name):\($0)" } ?? parameters.name
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
        }
        await server.withMethodHandler(UnencodableMethod.self) { _ in UnencodableResult() }
        return ServerHarness(server: server, transport: transport)
    }

    init(server: Server, transport: InMemoryTransport) {
        self.server = server
        self.transport = transport
    }

    func start() async throws { try await server.start(transport: transport) }

    func startAndInitialize() async throws {
        try await start()
        await send(initializeRequest(id: "initialize", version: Version.latest))
        _ = try await nextResponse()
        await send(notification(method: InitializedNotification.name))
    }

    func send(_ data: Data) async { await transport.push(data) }
    func finishInput() async { await transport.finishInput() }
    func failFutureWrites() async { await transport.failFutureWrites() }
    func nextResponse() async throws -> WireResponse { try JSONDecoder().decode(WireResponse.self, from: await transport.nextOutput()) }
    func nextResponseIfAvailable() async throws -> WireResponse? {
        guard let data = await transport.nextOutputIfAvailable() else { return nil }
        return try JSONDecoder().decode(WireResponse.self, from: data)
    }
    func waitUntilCompleted() async { await server.waitUntilCompleted() }
    func stop() async { await server.stop() }
    func waitUntilDisconnected() async -> Bool { await transport.waitUntilDisconnected() }
    func drainScheduling() async { await Task.yield(); await Task.yield(); await Task.yield() }

    var outputCount: Int { get async { await transport.outputs.count } }
    var disconnectCount: Int { get async { await transport.disconnectCount } }
    func responseCount(id: ID) async -> Int {
        await transport.outputs.compactMap { try? JSONDecoder().decode(WireResponse.self, from: $0) }.count { $0.id == id }
    }
}

private actor InMemoryTransport: Transport {
    nonisolated let logger: Logger
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var connected = false
    private(set) var disconnectCount = 0
    private(set) var outputs: [Data] = []
    private var nextOutputIndex = 0
    private var outputWaiters: [CheckedContinuation<Data, Never>] = []
    private var writesFail = false

    init(logger: Logger) {
        self.logger = logger
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws { connected = true }

    func disconnect() async {
        guard connected else { return }
        connected = false
        disconnectCount += 1
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected, !writesFail else { throw MCPError.internalError("fixture output unavailable") }
        outputs.append(data)
        if !outputWaiters.isEmpty {
            outputWaiters.removeFirst().resume(returning: data)
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }
    func push(_ data: Data) { continuation.yield(data) }
    func finishInput() { continuation.finish() }
    func failFutureWrites() { writesFail = true }

    func nextOutput() async -> Data {
        if nextOutputIndex < outputs.count {
            defer { nextOutputIndex += 1 }
            return outputs[nextOutputIndex]
        }
        let output = await withCheckedContinuation { outputWaiters.append($0) }
        nextOutputIndex += 1
        return output
    }

    func nextOutputIfAvailable() async -> Data? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while nextOutputIndex >= outputs.count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard nextOutputIndex < outputs.count else { return nil }
        defer { nextOutputIndex += 1 }
        return outputs[nextOutputIndex]
    }

    func waitUntilDisconnected() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while connected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !connected
    }
}

private actor ToolCallRecorder {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

private actor CallGate {
    private var started: Set<String> = []
    private var released: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ name: String) async {
        started.insert(name)
        startWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
        guard !released.contains(name) else { return }
        await withCheckedContinuation { releaseWaiters[name, default: []].append($0) }
    }

    func waitUntilStarted(_ name: String) async {
        guard !started.contains(name) else { return }
        await withCheckedContinuation { startWaiters[name, default: []].append($0) }
    }

    func release(_ name: String) {
        released.insert(name)
        releaseWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
    }
}

private struct FixtureFailure: Error { let message: String }

private enum UnencodableMethod: MCPStdio.Method {
    static let name = "testing/unencodable"
    typealias Result = UnencodableResult
}

private struct UnencodableResult: Hashable, Codable, Sendable {
    init() {}
    init(from decoder: Decoder) throws { self.init() }
    func encode(to encoder: Encoder) throws { throw FixtureFailure(message: "encoding fixture") }
}

private struct WireResponse: Codable, Equatable {
    let id: ID
    let result: Value?
    let error: WireError?

    var errorCode: Int? { error?.code }

    static func success(id: ID, result: Value) -> Self { .init(id: id, result: result, error: nil) }
    static func error(id: ID?, code: Int) -> Self { .init(id: id ?? .null, result: nil, error: .init(code: code)) }
}

private struct WireError: Codable, Equatable {
    let code: Int
    private enum CodingKeys: String, CodingKey { case code }
}

private func initializeRequest(id: ID, version: String) -> Data {
    request(id: id, method: Initialize.name, params: [
        "protocolVersion": .string(version),
        "capabilities": [:],
        "clientInfo": ["name": "fixture-client", "version": "1.0"]
    ])
}

private func cancel(id: ID) -> Data {
    notification(method: CancelledNotification.name, params: ["requestId": Value(from: id)])
}

private func request(id: ID, method: String, params: Value? = nil) -> Data {
    var object: [String: Value] = ["jsonrpc": "2.0", "id": Value(from: id), "method": .string(method)]
    if let params { object["params"] = params }
    return try! JSONEncoder().encode(Value.object(object))
}

private func notification(method: String, params: Value? = nil) -> Data {
    var object: [String: Value] = ["jsonrpc": "2.0", "method": .string(method)]
    if let params { object["params"] = params }
    return try! JSONEncoder().encode(Value.object(object))
}

private extension Value {
    init(from id: ID) {
        switch id {
        case .null: self = .null
        case let .string(value): self = .string(value)
        case let .int(value): self = .int(value)
        }
    }

    subscript(_ key: String) -> Value? { objectValue?[key] }
    subscript(_ index: Int) -> Value? { arrayValue?[index] }
}

private final class CapturedServerLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) { lock.withLock { messages.append(message) } }
    var joined: String { lock.withLock { messages.joined(separator: "\n") } }
}

private struct CapturingServerLogHandler: LogHandler {
    let captured: CapturedServerLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        captured.append(event.message.description)
    }
}

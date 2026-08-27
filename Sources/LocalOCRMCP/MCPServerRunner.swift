import Foundation
import Logging
import LocalOCRService
import MCPStdio

public protocol MCPToolDispatching: Sendable {
    func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result
}

extension MCPToolDispatcher: MCPToolDispatching {}

public struct MCPServerRunner: Sendable {
    private let dispatcher: any MCPToolDispatching

    public init(dispatcher: any MCPToolDispatching) {
        self.dispatcher = dispatcher
    }

    public func makeServer() async -> Server {
        let server = Server(
            name: "localocr",
            version: LocalOCRRuntime.version,
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPToolCatalog.tools)
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            await dispatcher.callTool(name: parameters.name, arguments: parameters.arguments)
        }

        return server
    }

    func run(
        transport: any Transport,
        beforeStart: @escaping @Sendable () async -> Void = {},
        cancellationCleanupDidRun: @escaping @Sendable () async -> Void = {},
        stopServer: @escaping @Sendable (Server) async -> Void = { server in
            await server.stop()
        }
    ) async throws {
        let server = await makeServer()
        let cancellationLatchedTransport = await CancellationLatchedTransport(
            transport,
            logger: transport.logger
        )
        let lifecycle = MCPServerLifecycleCoordinator(
            server: server,
            stopServer: stopServer
        )

        try await withTaskCancellationHandler {
            do {
                await beforeStart()

                do {
                    try await server.start(transport: cancellationLatchedTransport)
                } catch {
                    await cancellationLatchedTransport.disconnect()
                    await lifecycle.startDidFinish()
                    throw error
                }
                await lifecycle.startDidFinish()

                await server.waitUntilCompleted()
                await lifecycle.stopOnce()
                try Task.checkCancellation()
                try await lifecycle.checkCancellation()
            } catch {
                await lifecycle.stopOnce()
                throw error
            }
        } onCancel: {
            Task {
                await cancellationLatchedTransport.requestCancellation()
                await lifecycle.requestCancellation()
                await cancellationCleanupDidRun()
            }
        }
    }

    public func runStdio() async throws {
        try await run(transport: StdioTransport())
    }
}

private actor MCPServerLifecycleCoordinator {
    private let server: Server
    private let stopServer: @Sendable (Server) async -> Void
    private var cancellationRequested = false
    private var startFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopTask: Task<Void, Never>?

    init(
        server: Server,
        stopServer: @escaping @Sendable (Server) async -> Void
    ) {
        self.server = server
        self.stopServer = stopServer
    }

    func requestCancellation() {
        cancellationRequested = true
        _ = beginStopOnce()
    }

    func startDidFinish() {
        guard !startFinished else { return }
        startFinished = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
    }

    func stopOnce() async {
        await beginStopOnce().value
    }

    func checkCancellation() throws {
        if cancellationRequested {
            throw CancellationError()
        }
    }

    private func beginStopOnce() -> Task<Void, Never> {
        if let stopTask {
            return stopTask
        }

        let server = server
        let stopServer = stopServer
        let task = Task {
            await self.waitUntilStartFinishes()
            await stopServer(server)
        }
        stopTask = task
        return task
    }

    private func waitUntilStartFinishes() async {
        guard !startFinished else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor CancellationLatchedTransport: Transport {
    nonisolated let logger: Logger

    private let transport: any Transport
    private var cancellationRequested = false
    private var connectWasAttempted = false
    private var disconnectTask: Task<Void, Never>?

    init(_ transport: any Transport, logger: Logger) {
        self.transport = transport
        self.logger = logger
    }

    func connect() async throws {
        if cancellationRequested || Task.isCancelled {
            cancellationRequested = true
            throw CancellationError()
        }

        connectWasAttempted = true
        try await transport.connect()

        if cancellationRequested || Task.isCancelled {
            cancellationRequested = true
            _ = beginDisconnectOnce()
            throw CancellationError()
        }
    }

    func requestCancellation() {
        cancellationRequested = true
        if connectWasAttempted {
            _ = beginDisconnectOnce()
        }
    }

    func disconnect() async {
        await beginDisconnectOnce().value
    }

    func send(_ data: Data) async throws {
        try await transport.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        let transport = transport
        return AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                do {
                    let stream = await transport.receive()
                    for try await data in stream {
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    private func beginDisconnectOnce() -> Task<Void, Never> {
        if let disconnectTask {
            return disconnectTask
        }

        let transport = transport
        let task = Task {
            await transport.disconnect()
        }
        disconnectTask = task
        return task
    }
}

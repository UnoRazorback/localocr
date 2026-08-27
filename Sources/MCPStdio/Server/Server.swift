import Foundation
import Logging

/// A minimal stdio-oriented MCP server with strict JSON-RPC lifecycle rules.
public actor Server {
    public struct Configuration: Hashable, Codable, Sendable {
        public static let `default` = Configuration(strict: true)
        public static let strict = Configuration(strict: true)
        public var strict: Bool

        public init(strict: Bool = true) {
            self.strict = strict
        }
    }

    public struct Capabilities: Hashable, Codable, Sendable {
        public struct Tools: Hashable, Codable, Sendable {
            public var listChanged: Bool?
            public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
        }

        public var tools: Tools?
        public init(tools: Tools? = nil) { self.tools = tools }
    }

    public nonisolated let name: String
    public nonisolated let version: String
    public nonisolated let title: String?
    public nonisolated let instructions: String?
    public var capabilities: Capabilities
    public var configuration: Configuration

    private struct MethodHandler: Sendable {
        let call: @Sendable (Data, ID) async throws -> Data

        init<M: Method>(
            _ type: M.Type,
            handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
        ) {
            call = { data, id in
                let request = try JSONDecoder().decode(Request<M>.self, from: data)
                let result: M.Result
                do {
                    result = try await handler(request.params)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw HandlerFailure()
                }
                try Task.checkCancellation()
                do {
                    return try Server.makeEncoder().encode(M.response(id: id, result: result))
                } catch {
                    throw ResponseEncodingFailure()
                }
            }
        }
    }

    private struct HandlerFailure: Error {}
    private struct ResponseEncodingFailure: Error {}

    private enum ConnectionState {
        case idle
        case running
        case stopping
        case completed
    }

    private enum LifecycleState {
        case awaitingInitialize
        case awaitingInitialized
        case ready
    }

    private struct Envelope {
        let id: ID?
        let method: String
        var isNotification: Bool { id == nil }
    }

    private let registry = RequestRegistry()
    private var methodHandlers: [String: MethodHandler] = [:]
    private var transport: (any Transport)?
    private var receiveTask: Task<Void, Never>?
    private var connectionState = ConnectionState.idle
    private var lifecycleState = LifecycleState.awaitingInitialize

    public init(
        name: String,
        version: String,
        title: String? = nil,
        instructions: String? = nil,
        capabilities: Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.name = name
        self.version = version
        self.title = title
        self.instructions = instructions
        self.capabilities = capabilities
        self.configuration = configuration
    }

    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = MethodHandler(type, handler: handler)
        return self
    }

    public func start(transport: any Transport) async throws {
        guard connectionState == .idle else {
            throw MCPError.invalidRequest("server has already been started")
        }

        self.transport = transport
        do {
            try await transport.connect()
        } catch {
            self.transport = nil
            connectionState = .completed
            throw error
        }

        lifecycleState = .awaitingInitialize
        connectionState = .running
        let logger = await transport.logger
        logger.debug("MCP server started")
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: transport)
        }
    }

    public func waitUntilCompleted() async {
        let task = receiveTask
        await task?.value
    }

    public func stop() async {
        receiveTask?.cancel()
        await finishConnection()
    }

    private func receiveMessages(from transport: any Transport) async {
        do {
            let messages = await transport.receive()
            for try await data in messages {
                if Task.isCancelled { break }
                await handle(data)
            }
        } catch {
            let logger = await transport.logger
            logger.error("MCP input stopped with a transport error")
        }
        await finishConnection()
    }

    private func handle(_ data: Data) async {
        let envelope: Envelope
        do {
            envelope = try decodeEnvelope(data)
        } catch let failure as EnvelopeFailure {
            if failure.shouldRespond {
                await sendError(id: failure.id ?? .null, failure.error)
            }
            return
        } catch {
            await sendError(id: .null, .parseError(nil))
            return
        }

        if envelope.isNotification {
            await handleNotification(envelope, data: data)
        } else if let id = envelope.id {
            await handleRequest(envelope, id: id, data: data)
        }
    }

    private func handleNotification(_ envelope: Envelope, data: Data) async {
        switch envelope.method {
        case InitializedNotification.name:
            guard lifecycleState == .awaitingInitialized,
                  (try? JSONDecoder().decode(Message<InitializedNotification>.self, from: data)) != nil
            else { return }
            lifecycleState = .ready
        case CancelledNotification.name:
            guard let message = try? JSONDecoder().decode(Message<CancelledNotification>.self, from: data),
                  let id = message.params.requestId
            else { return }
            if await registry.cancel(id) {
                await sendError(id: id, .internalError("request cancelled"))
            }
        default:
            return
        }
    }

    private func handleRequest(_ envelope: Envelope, id: ID, data: Data) async {
        if envelope.method == Initialize.name {
            await handleInitialize(id: id, data: data)
            return
        }

        if configuration.strict, lifecycleState != .ready {
            await sendError(id: id, .invalidRequest("server is not initialized"))
            return
        }

        if envelope.method == Ping.name {
            await beginRequest(id: id, data: data, handler: MethodHandler(Ping.self) { _ in Empty() })
            return
        }

        guard let handler = methodHandlers[envelope.method] else {
            await sendError(id: id, .methodNotFound(nil))
            return
        }
        await beginRequest(id: id, data: data, handler: handler)
    }

    private func handleInitialize(id: ID, data: Data) async {
        guard lifecycleState == .awaitingInitialize else {
            await sendError(id: id, .invalidRequest("initialize has already been received"))
            return
        }
        guard await registry.reserve(id) else {
            await sendError(id: id, .invalidRequest("duplicate active request ID"))
            return
        }

        do {
            let request = try JSONDecoder().decode(Request<Initialize>.self, from: data)
            let protocolVersion = Version.negotiate(clientRequestedVersion: request.params.protocolVersion)
            let result = Initialize.Result(
                protocolVersion: protocolVersion,
                capabilities: try lifecycleCapabilities(),
                serverInfo: .init(name: name, version: version, title: title),
                instructions: instructions
            )
            let response = try Self.makeEncoder().encode(Initialize.response(id: id, result: result))
            lifecycleState = .awaitingInitialized
            if await registry.complete(id) {
                await sendFrame(response)
            }
        } catch {
            _ = await registry.complete(id)
            await sendError(id: id, .invalidParams(nil))
        }
    }

    private func beginRequest(id: ID, data: Data, handler: MethodHandler) async {
        guard await registry.reserve(id) else {
            await sendError(id: id, .invalidRequest("duplicate active request ID"))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await handler.call(data, id)
                try Task.checkCancellation()
                if await self.registry.complete(id) {
                    await self.sendFrame(response)
                }
            } catch is CancellationError {
                if await self.registry.complete(id) {
                    await self.sendError(id: id, .internalError("request cancelled"))
                }
            } catch is DecodingError {
                if await self.registry.complete(id) {
                    await self.sendError(id: id, .invalidParams(nil))
                }
            } catch is ResponseEncodingFailure {
                if await self.registry.complete(id) {
                    await self.failOutput()
                }
            } catch {
                if await self.registry.complete(id) {
                    await self.sendError(id: id, .internalError(nil))
                }
            }
        }
        await registry.attach(task, to: id)
    }

    private func sendError(id: ID, _ error: MCPError) async {
        do {
            let data = try Self.makeEncoder().encode(Ping.response(id: id, error: error))
            await sendFrame(data)
        } catch {
            await failOutput()
        }
    }

    private func sendFrame(_ data: Data) async {
        guard connectionState == .running, let transport else { return }
        do {
            try await transport.send(data)
        } catch {
            await failOutput()
        }
    }

    private func failOutput() async {
        if let transport {
            let logger = await transport.logger
            logger.error("MCP output stopped with a transport error")
        }
        await finishConnection()
    }

    private func finishConnection() async {
        guard connectionState == .running else { return }
        connectionState = .stopping
        _ = await registry.cancelAll()
        if let transport {
            await transport.disconnect()
        }
        transport = nil
        connectionState = .completed
    }

    private func lifecycleCapabilities() throws -> Initialize.ServerCapabilities {
        let data = try Self.makeEncoder().encode(capabilities)
        return try JSONDecoder().decode(Initialize.ServerCapabilities.self, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private enum EnvelopeFailure: Error {
        case parse
        case invalid(id: ID?, shouldRespond: Bool)

        var id: ID? {
            switch self {
            case .parse: nil
            case let .invalid(id, _): id
            }
        }

        var shouldRespond: Bool {
            switch self {
            case .parse: true
            case let .invalid(_, shouldRespond): shouldRespond
            }
        }

        var error: MCPError {
            switch self {
            case .parse: .parseError(nil)
            case .invalid: .invalidRequest(nil)
            }
        }
    }

    private func decodeEnvelope(_ data: Data) throws -> Envelope {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw EnvelopeFailure.parse
        }

        guard let object = try? JSONDecoder().decode(Value.self, from: data).objectValue else {
            throw EnvelopeFailure.invalid(id: nil, shouldRespond: true)
        }
        let idPresent = object.keys.contains("id")
        let id: ID?
        if idPresent {
            switch object["id"] {
            case .null: id = .null
            case let .string(value): id = .string(value)
            case let .int(value): id = .int(value)
            default: throw EnvelopeFailure.invalid(id: nil, shouldRespond: true)
            }
        } else {
            id = nil
        }

        let appearsToBeNotification: Bool
        if !idPresent, case .string? = object["method"] {
            appearsToBeNotification = true
        } else {
            appearsToBeNotification = false
        }
        guard object["jsonrpc"] == .string("2.0"),
              case let .string(method)? = object["method"]
        else {
            throw EnvelopeFailure.invalid(id: id, shouldRespond: !appearsToBeNotification)
        }
        return Envelope(id: id, method: method)
    }
}

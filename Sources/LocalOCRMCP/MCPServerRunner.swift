import LocalOCRService
import MCP

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

    func run(transport: any Transport) async throws {
        let server = await makeServer()
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await server.start(transport: transport)
                try Task.checkCancellation()
                await server.waitUntilCompleted()
                try Task.checkCancellation()
                await server.stop()
                try Task.checkCancellation()
            } catch {
                await server.stop()
                throw error
            }
        } onCancel: {
            Task {
                await server.stop()
            }
        }
    }

    public func runStdio() async throws {
        try await run(transport: StdioTransport())
    }
}

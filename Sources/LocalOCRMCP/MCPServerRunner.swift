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
            version: "0.2.0",
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

    public func run() async throws {
        let server = await makeServer()
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

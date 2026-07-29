import MCP

public protocol MCPToolDispatching: Sendable {
    func call(name: String, arguments: [String: Value]) async -> CallTool.Result
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
            await dispatcher.call(
                name: parameters.name,
                arguments: parameters.arguments ?? [:]
            )
        }

        return server
    }

    public func run(transport: any Transport) async throws {
        let server = await makeServer()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await server.stop()
    }

    public func runStdio() async throws {
        try await run(transport: StdioTransport())
    }
}

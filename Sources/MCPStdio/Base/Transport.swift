import Foundation
import Logging

/// The actor-isolated byte transport used by the local MCP server.
public protocol Transport: Actor {
    var logger: Logger { get }

    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() -> AsyncThrowingStream<Data, any Error>
}

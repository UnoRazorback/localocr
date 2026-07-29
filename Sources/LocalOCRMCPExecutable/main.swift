import Darwin
import Foundation
import LocalOCRMCP
import LocalOCRService

let dispatcher = MCPToolDispatcher(
    service: LocalOCRService(),
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)

do {
    try await MCPServerRunner(dispatcher: dispatcher).runStdio()
} catch {
    let message = "localocr-mcp: startup failed: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}

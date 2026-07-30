import Foundation
import LocalOCRMCP
import LocalOCRService

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let dispatcher = MCPToolDispatcher(service: LocalOCRService(), currentDirectory: currentDirectory)

do {
    try await MCPServerRunner(dispatcher: dispatcher).run()
} catch {
    FileHandle.standardError.write(Data("localocr-mcp: \(error)\n".utf8))
    exit(1)
}

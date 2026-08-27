import Foundation
import LocalOCRIntelligence
import LocalOCRMCP
import LocalOCRService

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let service = LocalOCRService()
let dispatcher = MCPToolDispatcher(
    service: service,
    textLoader: LocalOCRDocumentTextLoader(service: service),
    intelligence: UnavailableIntelligenceProvider(.requiresMacOS26),
    consentStore: ExternalDataConsentStore(),
    currentDirectory: currentDirectory
)

do {
    try await MCPServerRunner(dispatcher: dispatcher).run()
} catch {
    FileHandle.standardError.write(Data("localocr-mcp: \(error)\n".utf8))
    exit(1)
}

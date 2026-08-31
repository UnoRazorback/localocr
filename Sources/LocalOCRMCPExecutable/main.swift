import Foundation
import LocalOCRIntelligence
import LocalOCRMCP
import LocalOCRService

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let service = LocalOCRService()
let textLoader = LocalOCRDocumentTextLoader(service: service)
let intelligenceEnvironment = LocalIntelligenceEnvironment.live(
    bridgeLocator: RelativeModelBridgeExecutableLocator()
)
let dispatcher = MCPToolDispatcher(
    service: service,
    textLoader: textLoader,
    intelligence: intelligenceEnvironment.router,
    consentStore: ExternalDataConsentStore(),
    currentDirectory: currentDirectory
)

do {
    try await MCPServerRunner(dispatcher: dispatcher).runStdio()
} catch {
    FileHandle.standardError.write(Data("localocr-mcp: server failed\n".utf8))
    exit(1)
}

import Foundation
import LocalOCRIntelligence
import LocalOCRMCP
import LocalOCRService

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let service = LocalOCRService()
let textLoader = LocalOCRDocumentTextLoader(service: service)
let intelligence: any DocumentIntelligenceProviding
#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    intelligence = FoundationModelsIntelligenceProvider()
} else {
    intelligence = UnavailableIntelligenceProvider(.requiresMacOS26)
}
#else
intelligence = UnavailableIntelligenceProvider(.requiresMacOS26)
#endif
let dispatcher = MCPToolDispatcher(
    service: service,
    textLoader: textLoader,
    intelligence: intelligence,
    consentStore: ExternalDataConsentStore(),
    currentDirectory: currentDirectory
)

do {
    try await MCPServerRunner(dispatcher: dispatcher).runStdio()
} catch {
    FileHandle.standardError.write(Data("localocr-mcp: server failed\n".utf8))
    exit(1)
}

import Foundation
import ArgumentParser
import LocalOCRService

struct SearchableCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(SearchableSyntax.self, arguments: arguments)
        let outputURL = options.output.map(URL.init(fileURLWithPath:))
        let request = try SearchablePDFRequest(fileURL: URL(fileURLWithPath: options.file), outputURL: outputURL, dpi: options.dpi, forceOCR: options.forceOCR, usesCache: !options.noCache)
        let response = try await service.makeSearchablePDF(request, progress: output.progress)
        options.json ? output.json(response) : output.stdout(response.outputPath + "\n")
        if !options.json, !response.failedPages.isEmpty {
            output.failedPages(response.failedPages)
        }
        return response.failedPages.isEmpty ? CLIExitCode.success.rawValue : CLIExitCode.partialResult.rawValue
    }
}

private struct SearchableSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "searchable")
    @Argument var file: String
    @Option(name: .long) var output: String?
    @Option(name: .long) var dpi = 250
    @Flag(name: .customLong("force-ocr")) var forceOCR = false
    @Flag(name: .customLong("no-cache")) var noCache = false
    @Flag(name: .long) var json = false

    mutating func validate() throws { try validateDPI(dpi) }
}

import Foundation
import ArgumentParser
import LocalOCRCore
import LocalOCRService

struct OCRCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(OCRSyntax.self, arguments: arguments)
        let request = try PDFOCRRequest(fileURL: URL(fileURLWithPath: options.file), pageRange: options.pages, dpi: options.dpi, forceOCR: options.forceOCR, includeLines: options.detail, usesCache: !options.noCache)
        let response = try await service.ocrPDF(request, progress: output.progress)
        options.json ? output.json(response) : output.stdout(textOutput(for: response))
        if !options.json, !response.failedPages.isEmpty {
            output.failedPages(response.failedPages)
        }
        return response.failedPages.isEmpty ? CLIExitCode.success.rawValue : CLIExitCode.partialResult.rawValue
    }
}

private struct OCRSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "ocr")
    @Argument var file: String
    @Option(name: .long) var pages: String?
    @Option(name: .long) var dpi = 250
    @Flag(name: .customLong("force-ocr")) var forceOCR = false
    @Flag(name: .long) var detail = false
    @Flag(name: .customLong("no-cache")) var noCache = false
    @Flag(name: .long) var json = false

    mutating func validate() throws {
        try validateDPI(dpi)
        try validatePageSpecification(pages)
    }
}

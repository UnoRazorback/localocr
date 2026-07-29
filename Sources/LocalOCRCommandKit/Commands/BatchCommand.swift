import Foundation
import ArgumentParser
import LocalOCRService

struct BatchCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(BatchSyntax.self, arguments: arguments)
        let request = try BatchOCRRequest(fileURLs: options.files.map(URL.init(fileURLWithPath:)), pageRange: options.pages, dpi: options.dpi, forceOCR: options.forceOCR, includeLines: options.detail, usesCache: !options.noCache)
        let response = await service.ocrPDFBatch(request, progress: output.batchProgress)
        if options.json {
            output.json(response)
        } else {
            for item in response.results {
                switch item {
                case let .success(ocr): output.stdout("--- \(ocr.sourcePath) ---\n\(textOutput(for: ocr))")
                case let .failure(sourcePath, message): output.stdout("--- \(sourcePath) ---\n\(message)\n")
                }
            }
        }
        return response.failed == 0 ? CLIExitCode.success.rawValue : CLIExitCode.partialResult.rawValue
    }
}

private struct BatchSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "batch")
    @Argument var files: [String]
    @Option(name: .long) var pages: String?
    @Option(name: .long) var dpi = 250
    @Flag(name: .customLong("force-ocr")) var forceOCR = false
    @Flag(name: .long) var detail = false
    @Flag(name: .customLong("no-cache")) var noCache = false
    @Flag(name: .long) var json = false

    mutating func validate() throws {
        guard !files.isEmpty else { throw ValidationError("expected at least one input file") }
        try validateDPI(dpi)
    }
}

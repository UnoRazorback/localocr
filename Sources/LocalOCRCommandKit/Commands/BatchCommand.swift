import Foundation
import LocalOCRService

extension CLIApplication {
    func runBatch(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(
            arguments: arguments,
            valueOptions: ["--pages", "--dpi"],
            flags: ["--force-ocr", "--detail", "--no-cache", "--json"]
        )
        guard !parsed.positional.isEmpty else {
            throw CLIArgumentError.message("batch requires at least one file")
        }
        let request = try BatchOCRRequest(
            fileURLs: parsed.positional.map(URL.init(fileURLWithPath:)),
            pageRange: try parsed.singleValue("--pages"),
            dpi: try parsed.dpi(),
            forceOCR: parsed.flags.contains("--force-ocr"),
            includeLines: parsed.flags.contains("--detail"),
            usesCache: !parsed.flags.contains("--no-cache")
        )
        let response = await service.ocrPDFBatch(request) { event in
            reportOCRProgress(event.progress, command: "batch")
        }
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            for item in response.results {
                switch item {
                case let .success(result):
                    output.stdout("--- \(result.sourcePath) ---\n")
                    writeOCRPages(result)
                case let .failure(sourcePath, message):
                    output.stderr("--- \(sourcePath) ---\nerror: \(message)\n")
                }
            }
        }
        guard response.processed == request.fileURLs.count else {
            output.stderr("batch: operation cancelled\n")
            return 4
        }
        return response.failed == 0 ? 0 : 3
    }
}

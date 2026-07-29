import Foundation
import LocalOCRService

extension CLIApplication {
    func runOCR(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(
            arguments: arguments,
            valueOptions: ["--pages", "--dpi"],
            flags: ["--force-ocr", "--detail", "--no-cache", "--json"]
        )
        guard parsed.positional.count == 1 else {
            throw CLIArgumentError.message("ocr requires one file")
        }
        let request = try PDFOCRRequest(
            fileURL: URL(fileURLWithPath: parsed.positional[0]),
            pageRange: try parsed.singleValue("--pages"),
            dpi: try parsed.dpi(),
            forceOCR: parsed.flags.contains("--force-ocr"),
            includeLines: parsed.flags.contains("--detail"),
            usesCache: !parsed.flags.contains("--no-cache")
        )
        let response = try await service.ocrPDF(request) { event in
            reportOCRProgress(event, command: "ocr")
        }
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            writeOCRPages(response)
        }
        return response.failedPages.isEmpty ? 0 : 3
    }
}

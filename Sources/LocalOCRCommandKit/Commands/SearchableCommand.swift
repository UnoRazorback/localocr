import Foundation
import LocalOCRService

extension CLIApplication {
    func runSearchable(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(
            arguments: arguments,
            valueOptions: ["--output", "--dpi"],
            flags: ["--force-ocr", "--no-cache", "--json"]
        )
        guard parsed.positional.count == 1 else {
            throw CLIArgumentError.message("searchable requires one file")
        }
        let outputURL = try parsed.singleValue("--output").map(URL.init(fileURLWithPath:))
        let request = try SearchablePDFRequest(
            fileURL: URL(fileURLWithPath: parsed.positional[0]),
            outputURL: outputURL,
            dpi: try parsed.dpi(),
            forceOCR: parsed.flags.contains("--force-ocr"),
            usesCache: !parsed.flags.contains("--no-cache")
        )
        let response = try await service.makeSearchablePDF(request) { event in
            reportOCRProgress(event, command: "searchable")
        }
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            output.stdout(response.outputPath + "\n")
        }
        return response.failedPages.isEmpty ? 0 : 3
    }
}

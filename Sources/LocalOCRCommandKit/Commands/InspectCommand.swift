import Foundation
import LocalOCRService

extension CLIApplication {
    func runInspect(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(arguments: arguments, valueOptions: [], flags: ["--json"])
        guard parsed.positional.count == 1 else {
            throw CLIArgumentError.message("inspect requires one file")
        }
        let response = try await service.inspectPDF(at: URL(fileURLWithPath: parsed.positional[0]))
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            output.stdout("\(response.pages) pages; \(response.searchablePages) searchable; \(response.ocrNeededPages) need OCR; \(response.characters) characters\n")
        }
        return 0
    }
}

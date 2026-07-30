import Foundation
import LocalOCRService

extension CLIApplication {
    func runPageCount(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(arguments: arguments, valueOptions: [], flags: ["--json"])
        guard parsed.positional.count == 1 else {
            throw CLIArgumentError.message("page-count requires one file")
        }
        let response = try await service.pageCount(at: URL(fileURLWithPath: parsed.positional[0]))
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            output.stdout("\(response.pages)\n")
        }
        return 0
    }
}

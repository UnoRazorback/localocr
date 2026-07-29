import Foundation
import LocalOCRService

extension CLIApplication {
    func runImage(arguments: [String]) async throws -> Int32 {
        let parsed = try ParsedCommandOptions(
            arguments: arguments,
            valueOptions: ["--language"],
            flags: ["--no-language-correction", "--json"]
        )
        guard parsed.positional.count == 1 else {
            throw CLIArgumentError.message("image requires one file")
        }
        let response = try await service.ocrImage(
            ImageOCRRequest(
                fileURL: URL(fileURLWithPath: parsed.positional[0]),
                recognitionLanguages: parsed.values["--language", default: []],
                usesLanguageCorrection: !parsed.flags.contains("--no-language-correction")
            )
        )
        if parsed.flags.contains("--json") {
            writeJSON(response)
        } else {
            output.stdout(response.text + "\n")
        }
        return 0
    }
}

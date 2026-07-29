import Foundation
import ArgumentParser
import LocalOCRService

struct InspectCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(InspectSyntax.self, arguments: arguments)
        let response = try await service.inspectPDF(at: URL(fileURLWithPath: options.file))
        if options.json {
            output.json(response)
        } else {
            output.stdout("Pages: \(response.pages) | Searchable: \(response.searchablePages) | OCR needed: \(response.ocrNeededPages) | Characters: \(response.characters)\n")
        }
        return CLIExitCode.success.rawValue
    }
}

private struct InspectSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "inspect")
    @Argument var file: String
    @Flag(name: .long) var json = false
}

import Foundation
import ArgumentParser
import LocalOCRService

struct PageCountCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(PageCountSyntax.self, arguments: arguments)
        let response = try await service.pageCount(at: URL(fileURLWithPath: options.file))
        options.json ? output.json(response) : output.stdout("\(response.pages)\n")
        return CLIExitCode.success.rawValue
    }
}

private struct PageCountSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "page-count")
    @Argument var file: String
    @Flag(name: .long) var json = false
}

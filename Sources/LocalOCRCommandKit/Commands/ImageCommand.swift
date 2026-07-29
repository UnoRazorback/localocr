import Foundation
import ArgumentParser
import LocalOCRService

struct ImageCommand {
    let service: any LocalOCRServing
    let output: CommandOutput

    func run(_ arguments: [String]) async throws -> Int32 {
        let options = try parseCLI(ImageSyntax.self, arguments: arguments)
        let response = try await service.ocrImage(.init(fileURL: URL(fileURLWithPath: options.file), recognitionLanguages: options.language, usesLanguageCorrection: !options.noLanguageCorrection))
        options.json ? output.json(response) : output.stdout(response.text + "\n")
        return CLIExitCode.success.rawValue
    }
}

private struct ImageSyntax: CLISyntax {
    static let configuration = CommandConfiguration(commandName: "image")
    @Argument var file: String
    @Option(name: .long) var language: [String] = []
    @Flag(name: .customLong("no-language-correction")) var noLanguageCorrection = false
    @Flag(name: .long) var json = false
}

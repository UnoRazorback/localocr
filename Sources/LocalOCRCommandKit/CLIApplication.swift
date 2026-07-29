import Foundation
import ArgumentParser
import LocalOCRCore
import LocalOCRService

public struct CLIApplication: Sendable {
    private let service: any LocalOCRServing
    private let output: CommandOutput

    public init(service: any LocalOCRServing, output: CommandOutput) {
        self.service = service
        self.output = output
    }

    public func run(arguments: [String]) async -> Int32 {
        do {
            if arguments == ["--version"] {
                output.stdout(LocalOCRRuntime.version + "\n")
                return CLIExitCode.success.rawValue
            }
            guard let name = arguments.first else {
                output.stdout(Self.help)
                return CLIExitCode.invalidArguments.rawValue
            }
            if name == "--help" || name == "-h" {
                output.stdout(Self.help)
                return CLIExitCode.success.rawValue
            }

            let remaining = Array(arguments.dropFirst())
            if remaining.contains("--help") || remaining.contains("-h") {
                guard Self.commandNames.contains(name) else { throw CLIError.invalidArguments("unknown command '\(name)'") }
                output.stdout(Self.help(for: name))
                return CLIExitCode.success.rawValue
            }

            switch name {
            case "page-count": return try await PageCountCommand(service: service, output: output).run(remaining)
            case "inspect": return try await InspectCommand(service: service, output: output).run(remaining)
            case "ocr": return try await OCRCommand(service: service, output: output).run(remaining)
            case "batch": return try await BatchCommand(service: service, output: output).run(remaining)
            case "image": return try await ImageCommand(service: service, output: output).run(remaining)
            case "searchable": return try await SearchableCommand(service: service, output: output).run(remaining)
            default: throw CLIError.invalidArguments("unknown command '\(name)'")
            }
        } catch is CancellationError {
            return CLIExitCode.cancelled.rawValue
        } catch let error as LocalOCRError where error == .cancelled {
            return CLIExitCode.cancelled.rawValue
        } catch let error as CLIError {
            output.error(error)
            return CLIExitCode.invalidArguments.rawValue
        } catch {
            output.error(error)
            return CLIExitCode.operationFailure.rawValue
        }
    }

    static let commandNames = ["page-count", "inspect", "ocr", "batch", "image", "searchable"]

    static let help = """
    Usage: localocr <command> [options]

    Commands:
      page-count <file> [--json]
      inspect <file> [--json]
      ocr <file> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]
      batch <files...> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]
      image <file> [--language <bcp47>]... [--no-language-correction] [--json]
      searchable <file> [--output <file>] [--dpi <72...600>] [--force-ocr] [--no-cache] [--json]
    """ + "\n"

    static func help(for command: String) -> String {
        let line = help.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command + " ") }
        return "Usage: localocr " + (line?.trimmingCharacters(in: .whitespaces) ?? command) + "\n"
    }
}

func parseCLI<Arguments: ParsableArguments>(
    _ type: Arguments.Type,
    arguments: [String]
) throws -> Arguments {
    do {
        return try type.parse(arguments)
    } catch {
        throw CLIError.invalidArguments(type.message(for: error).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

protocol CLISyntax: AsyncParsableCommand {
    var json: Bool { get }
}

extension CLISyntax {
    mutating func run() async throws {}
}

func validateDPI(_ dpi: Int) throws {
    guard (72 ... 600).contains(dpi) else {
        throw ValidationError("--dpi must be an integer from 72 through 600")
    }
}

func textOutput(for response: PDFOCRResponse) -> String {
    response.pages.map { "--- Page \($0.page) ---\n\($0.text)" }.joined(separator: "\n\n") + "\n"
}

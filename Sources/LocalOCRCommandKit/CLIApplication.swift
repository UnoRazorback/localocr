import Foundation
import LocalOCRCore
import LocalOCRService

enum CLIArgumentError: Error, Sendable, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

struct ParsedCommandOptions: Sendable {
    let positional: [String]
    let values: [String: [String]]
    let flags: Set<String>

    init(arguments: [String], valueOptions: Set<String>, flags: Set<String>) throws {
        var positional: [String] = []
        var values: [String: [String]] = [:]
        var enabledFlags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw CLIArgumentError.message("missing value for \(argument)")
                }
                values[argument, default: []].append(arguments[index + 1])
                index += 2
            } else if flags.contains(argument) {
                guard enabledFlags.insert(argument).inserted else {
                    throw CLIArgumentError.message("duplicate option \(argument)")
                }
                index += 1
            } else if argument.hasPrefix("--") {
                throw CLIArgumentError.message("unknown option \(argument)")
            } else {
                positional.append(argument)
                index += 1
            }
        }

        self.positional = positional
        self.values = values
        self.flags = enabledFlags
    }

    func singleValue(_ option: String) throws -> String? {
        let options = values[option, default: []]
        guard options.count <= 1 else {
            throw CLIArgumentError.message("duplicate option \(option)")
        }
        return options.first
    }

    func dpi() throws -> Int {
        guard let rawDPI = try singleValue("--dpi") else { return 250 }
        guard let dpi = Int(rawDPI), (72 ... 600).contains(dpi) else {
            throw CLIArgumentError.message("--dpi must be an integer from 72 through 600")
        }
        return dpi
    }
}

public struct CLIApplication: Sendable {
    let service: any LocalOCRServing
    let output: CommandOutput

    public init(service: any LocalOCRServing, output: CommandOutput) {
        self.service = service
        self.output = output
    }

    public func run(arguments: [String]) async -> Int32 {
        do {
            try Task.checkCancellation()
            guard let command = arguments.first else {
                output.stdout(Self.rootHelp)
                return 0
            }

            if command == "--help" || command == "-h" {
                output.stdout(Self.rootHelp)
                return 0
            }
            if command == "--version" || command == "-V" {
                output.stdout("\(LocalOCRRuntime.version)\n")
                return 0
            }

            let remainder = Array(arguments.dropFirst())
            if remainder.contains("--help") || remainder.contains("-h") {
                guard Self.help(for: command) != nil else {
                    throw CLIArgumentError.message("unknown command \(command)")
                }
                output.stdout(Self.help(for: command)!)
                return 0
            }

            switch command {
            case "page-count": return try await runPageCount(arguments: remainder)
            case "inspect": return try await runInspect(arguments: remainder)
            case "ocr": return try await runOCR(arguments: remainder)
            case "batch": return try await runBatch(arguments: remainder)
            case "image": return try await runImage(arguments: remainder)
            case "searchable": return try await runSearchable(arguments: remainder)
            default: throw CLIArgumentError.message("unknown command \(command)")
            }
        } catch is CancellationError {
            output.stderr("operation cancelled\n")
            return 4
        } catch let error as LocalOCRError where error == .cancelled {
            output.stderr("operation cancelled\n")
            return 4
        } catch let error as CLIArgumentError {
            output.stderr("error: \(error.description)\n")
            return 2
        } catch {
            output.stderr("error: \(error)\n")
            return 1
        }
    }

    func writeJSON<Response: Encodable>(_ response: Response) {
        output.stdout(String(decoding: ResponseEncoding.encode(response), as: UTF8.self) + "\n")
    }

    func writeOCRPages(_ response: PDFOCRResponse) {
        for page in response.pages {
            output.stdout("--- Page \(page.page) ---\n\(page.text)\n")
        }
    }

    func reportOCRProgress(_ event: OCRProgress, command: String) {
        switch event {
        case .inspecting: output.stderr("\(command): inspecting\n")
        case let .recognizing(page, total): output.stderr("\(command): recognizing page \(page)/\(total)\n")
        case .assembling: output.stderr("\(command): assembling\n")
        case .completed: output.stderr("\(command): completed\n")
        }
    }

    static let rootHelp = """
    Usage: localocr <command> [options]

    Commands: page-count, inspect, ocr, batch, image, searchable
    """ + "\n"

    static func help(for command: String) -> String? {
        switch command {
        case "page-count": "Usage: localocr page-count <file> [--json]\n"
        case "inspect": "Usage: localocr inspect <file> [--json]\n"
        case "ocr": "Usage: localocr ocr <file> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]\n"
        case "batch": "Usage: localocr batch <files...> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]\n"
        case "image": "Usage: localocr image <file> [--language <bcp47>]... [--no-language-correction] [--json]\n"
        case "searchable": "Usage: localocr searchable <file> [--output <file>] [--dpi <72...600>] [--force-ocr] [--no-cache] [--json]\n"
        default: nil
        }
    }
}

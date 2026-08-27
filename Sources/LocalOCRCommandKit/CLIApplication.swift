import Foundation
import LocalOCRCore
import LocalOCRIntelligence
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
    let consentStore: any ExternalDataConsentStoring
    let consentIO: any ConsentCommandIO

    public init(
        service: any LocalOCRServing,
        output: CommandOutput,
        consentStore: any ExternalDataConsentStoring = ExternalDataConsentStore(),
        consentIO: any ConsentCommandIO = StandardConsentCommandIO()
    ) {
        self.service = service
        self.output = output
        self.consentStore = consentStore
        self.consentIO = consentIO
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
                if command == "mcp-consent", let operation = remainder.first,
                   let leafHelp = Self.mcpConsentHelp(for: operation)
                {
                    output.stdout(leafHelp)
                    return 0
                }
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
            case "mcp-consent": return try await runMCPConsent(arguments: remainder)
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

    Commands: page-count, inspect, ocr, batch, image, searchable, mcp-consent
    """ + "\n"

    static func help(for command: String) -> String? {
        switch command {
        case "page-count": "Usage: localocr page-count <file> [--json]\n"
        case "inspect": "Usage: localocr inspect <file> [--json]\n"
        case "ocr": "Usage: localocr ocr <file> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]\n"
        case "batch": "Usage: localocr batch <files...> [--pages <spec>] [--dpi <72...600>] [--force-ocr] [--detail] [--no-cache] [--json]\n"
        case "image": "Usage: localocr image <file> [--language <bcp47>]... [--no-language-correction] [--json]\n"
        case "searchable": "Usage: localocr searchable <file> [--output <file>] [--dpi <72...600>] [--force-ocr] [--no-cache] [--json]\n"
        case "mcp-consent": "Usage: localocr mcp-consent <status|accept|revoke>\n"
        default: nil
        }
    }

    static func mcpConsentHelp(for operation: String) -> String? {
        switch operation {
        case "status": "Usage: localocr mcp-consent status\n"
        case "accept": "Usage: localocr mcp-consent accept\n\nRequires an interactive terminal and two confirmations.\n"
        case "revoke": "Usage: localocr mcp-consent revoke\n"
        default: nil
        }
    }

    func runMCPConsent(arguments: [String]) async throws -> Int32 {
        guard arguments.count == 1, let operation = arguments.first else {
            throw CLIArgumentError.message("usage: localocr mcp-consent <status|accept|revoke>")
        }

        switch operation {
        case "status":
            switch await consentStore.status() {
            case .current:
                consentIO.stdout("current\n")
                return 0
            case .required:
                consentIO.stdout("required\n")
                return 2
            }
        case "accept":
            return try await acceptMCPConsent()
        case "revoke":
            try await consentStore.revoke()
            consentIO.stdout("revoked\n")
            return 0
        default:
            throw CLIArgumentError.message("unknown mcp-consent operation \(operation)")
        }
    }

    private func acceptMCPConsent() async throws -> Int32 {
        guard consentIO.isTerminal else {
            consentIO.stderr("error: mcp-consent accept requires an interactive terminal\n")
            return 2
        }

        consentIO.stdout(Self.externalDataDisclosure + "\n\n")
        consentIO.stdout(Self.externalProviderRiskAcknowledgment + "\n")
        guard promptForAcknowledgment("Accept external-provider transmission risk? [y/N] ") else {
            return 2
        }
        consentIO.stdout(Self.documentToolAccessAcknowledgment + "\n")
        guard promptForAcknowledgment("Allow LocalOCR MCP document tools to access chosen files? [y/N] ") else {
            return 2
        }

        try await consentStore.acceptBothStatements(at: Date())
        consentIO.stdout("accepted\n")
        return 0
    }

    private func promptForAcknowledgment(_ prompt: String) -> Bool {
        consentIO.stdout(prompt)
        guard let answer = consentIO.readLine() else { return false }
        return ["y", "yes"].contains(answer.lowercased())
    }

    static let externalDataDisclosure = """
    LocalOCR and Apple Foundation Models process documents locally on this Mac,
    and LocalOCR does not upload them. When you connect LocalOCR to an agent
    through MCP, that MCP client or its AI provider may send filenames, paths,
    document text, summaries, extracted fields, and tool results to an outside
    service. Transmission, retention, model training, and other handling are
    controlled by the agent and provider, not LocalOCR. Review their privacy and
    data policies, and only continue if you are authorized to share the data.
    """

    static let externalProviderRiskAcknowledgment = "I understand that my MCP client or agent may transmit LocalOCR inputs and results to an outside provider."
    static let documentToolAccessAcknowledgment = "I confirm that I am authorized to share this data and choose to enable LocalOCR MCP document tools."
}

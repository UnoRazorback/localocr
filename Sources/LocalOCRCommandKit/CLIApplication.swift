import Foundation
import LocalOCRCore
import LocalOCRIntelligence
import LocalOCRModelCore
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
    let intelligenceManager: (any LocalIntelligenceManaging)?
    let now: @Sendable () -> Date

    public init(
        service: any LocalOCRServing,
        output: CommandOutput,
        consentStore: any ExternalDataConsentStoring = ExternalDataConsentStore(),
        consentIO: any ConsentCommandIO = StandardConsentCommandIO(),
        intelligenceManager: (any LocalIntelligenceManaging)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.output = output
        self.consentStore = consentStore
        self.consentIO = consentIO
        self.intelligenceManager = intelligenceManager
        self.now = now
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
                if command == "intelligence", let operation = remainder.first,
                   let leafHelp = Self.intelligenceHelp(for: operation)
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
            case "intelligence": return try await runIntelligence(arguments: remainder)
            default: throw CLIArgumentError.message("unknown command \(command)")
            }
        } catch is CancellationError {
            output.stderr("operation cancelled\n")
            return 4
        } catch let error as LocalOCRError where error == .cancelled {
            output.stderr("operation cancelled\n")
            return 4
        } catch let error as IntelligenceError {
            let mapped = Self.intelligenceExit(for: error)
            output.stderr("error: \(Self.intelligenceErrorCode(error))\n")
            return mapped
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

    Commands: page-count, inspect, ocr, batch, image, searchable, mcp-consent, intelligence
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
        case "intelligence": "Usage: localocr intelligence <models|test|select|status|reset>\n"
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

    static func intelligenceHelp(for operation: String) -> String? {
        switch operation {
        case "models": "Usage: localocr intelligence models [--json]\n"
        case "test": "Usage: localocr intelligence test <provider> <model> [--json]\n"
        case "select": "Usage: localocr intelligence select <provider> <model>\n"
        case "status": "Usage: localocr intelligence status [--json]\n"
        case "reset": "Usage: localocr intelligence reset [--json]\n"
        default: nil
        }
    }

    func runIntelligence(arguments: [String]) async throws -> Int32 {
        guard let manager = intelligenceManager else {
            throw MissingIntelligenceManagerError.unavailable
        }
        guard let operation = arguments.first else {
            throw CLIArgumentError.message(
                "usage: localocr intelligence <models|test|select|status|reset>"
            )
        }
        let options = try ParsedCommandOptions(
            arguments: Array(arguments.dropFirst()),
            valueOptions: [],
            flags: operation == "select" ? [] : ["--json"]
        )
        switch operation {
        case "models":
            guard options.positional.isEmpty else {
                throw CLIArgumentError.message("usage: localocr intelligence models [--json]")
            }
            let descriptors = await manager.models().sorted(by: Self.intelligenceDescriptorOrder)
            if options.flags.contains("--json") {
                writeJSON(IntelligenceModelsResponse(models: descriptors.map(IntelligenceModelResponse.init)))
            } else {
                output.stdout(IntelligenceModelResponse.textHeader)
                for descriptor in descriptors {
                    output.stdout(IntelligenceModelResponse(descriptor).textLine)
                }
            }
            return 0
        case "test":
            guard options.positional.count == 2 else {
                throw CLIArgumentError.message(
                    "usage: localocr intelligence test <provider> <model> [--json]"
                )
            }
            let descriptor = try await exactDescriptor(
                manager: manager,
                provider: options.positional[0],
                model: options.positional[1]
            )
            try validateTestCandidate(descriptor)
            let outcome = try await manager.qualify(descriptor.identity)
            let response = IntelligenceQualificationResponse(
                descriptor: descriptor,
                outcome: outcome
            )
            if options.flags.contains("--json") {
                writeJSON(response)
            } else {
                output.stdout(response.text)
            }
            return outcome.status == .passed ? 0 : 2
        case "select":
            guard options.positional.count == 2 else {
                throw CLIArgumentError.message(
                    "usage: localocr intelligence select <provider> <model>"
                )
            }
            let descriptor = try await exactDescriptor(
                manager: manager,
                provider: options.positional[0],
                model: options.positional[1]
            )
            try validateSelectionCandidate(descriptor)
            if descriptor.identity.provider == .appleFoundationModels {
                guard descriptor.identity == .appleSystemDefault else {
                    throw CLIArgumentError.message("invalid Apple system model identity")
                }
                try await manager.selectApple()
                consentIO.stdout(
                    "selected apple_foundation_models SystemLanguageModel.default\n"
                )
                return 0
            }
            guard consentIO.isTerminal else {
                consentIO.stderr(
                    "error: external model selection requires an interactive terminal\n"
                )
                return 2
            }
            consentIO.stdout(Self.externalModelDisclosure(for: descriptor.identity))
            guard let answer = consentIO.readLine(),
                  !consentIO.hasPendingInput,
                  answer == "y" || answer == "yes"
            else {
                return 2
            }
            try await manager.selectExternal(
                descriptor.identity,
                acknowledgmentAcceptedAt: now()
            )
            consentIO.stdout(
                "\nselected \(intelligenceTextField(descriptor.identity.provider.rawValue)) \(intelligenceTextField(descriptor.identity.model))\n"
            )
            return 0
        case "status":
            guard options.positional.isEmpty else {
                throw CLIArgumentError.message("usage: localocr intelligence status [--json]")
            }
            let response = IntelligenceStatusResponse(await manager.status())
            if options.flags.contains("--json") {
                writeJSON(response)
            } else {
                output.stdout(response.text)
            }
            return response.state == "invalid" ? 2 : 0
        case "reset":
            guard options.positional.isEmpty else {
                throw CLIArgumentError.message("usage: localocr intelligence reset [--json]")
            }
            try await manager.reset()
            if options.flags.contains("--json") {
                writeJSON(IntelligenceResetResponse(state: "reset"))
            } else {
                output.stdout("reset\n")
            }
            return 0
        default:
            throw CLIArgumentError.message("unknown intelligence operation \(operation)")
        }
    }

    private func exactDescriptor(
        manager: any LocalIntelligenceManaging,
        provider: String,
        model: String
    ) async throws -> LocalModelDescriptor {
        guard LocalModelProviderID(rawValue: provider) != nil,
              !model.isEmpty
        else {
            throw CLIArgumentError.message("invalid provider or model")
        }
        let matches = await manager.models().filter {
            $0.identity.provider.rawValue == provider && $0.identity.model == model
        }
        guard matches.count == 1, let descriptor = matches.first else {
            let reason = matches.isEmpty ? "model not found" : "model identity is ambiguous"
            throw CLIArgumentError.message(reason)
        }
        return descriptor
    }

    private func validateTestCandidate(_ descriptor: LocalModelDescriptor) throws {
        guard descriptor.identity.provider != .appleFoundationModels else {
            throw CLIArgumentError.message("Apple system model does not require qualification")
        }
        try validateAvailableAndLocal(descriptor)
    }

    private func validateSelectionCandidate(_ descriptor: LocalModelDescriptor) throws {
        try validateAvailableAndLocal(descriptor)
        if descriptor.identity.provider != .appleFoundationModels,
           descriptor.qualification != .passed {
            throw CLIArgumentError.message("model qualification is not current")
        }
    }

    private func validateAvailableAndLocal(_ descriptor: LocalModelDescriptor) throws {
        guard descriptor.available else {
            throw CLIArgumentError.message("model is unavailable")
        }
        switch descriptor.locality {
        case .verifiedLocal:
            return
        case .blocked:
            throw CLIArgumentError.message("model locality is blocked")
        case .unverified:
            throw CLIArgumentError.message("model locality is unverified")
        }
    }

    private static func externalModelDisclosure(for identity: LocalModelIdentity) -> String {
        """
        LocalOCR will send OCR text to the selected third-party model harness over loopback on this Mac. The harness may keep its own logs or history. Review its privacy settings before continuing.
        Selected provider: \(intelligenceTextField(intelligenceProviderDisplayName(identity.provider)))
        Selected model: \(intelligenceTextField(identity.model))
        Send future LocalOCR intelligence text to this local harness? [y/N]
        """
    }

    private static func intelligenceDescriptorOrder(
        _ lhs: LocalModelDescriptor,
        _ rhs: LocalModelDescriptor
    ) -> Bool {
        let order: [LocalModelProviderID: Int] = [
            .appleFoundationModels: 0,
            .ollama: 1,
            .lmStudio: 2
        ]
        let left = order[lhs.identity.provider] ?? 3
        let right = order[rhs.identity.provider] ?? 3
        if left != right { return left < right }
        if lhs.identity.model != rhs.identity.model {
            return lhs.identity.model < rhs.identity.model
        }
        if lhs.identity.fingerprint != rhs.identity.fingerprint {
            return (lhs.identity.fingerprint ?? "") < (rhs.identity.fingerprint ?? "")
        }
        return (lhs.identity.harnessVersion ?? "") < (rhs.identity.harnessVersion ?? "")
    }

    private static func intelligenceExit(for error: IntelligenceError) -> Int32 {
        switch error {
        case .cancelled:
            4
        case .unavailable, .selection:
            2
        case .emptyDocument, .invalidFields, .bridgeUnavailable, .bridgeInvalid,
             .generationTimedOut, .generationFailed, .contextOverflow, .malformedOutput,
             .ungroundedOutput:
            1
        }
    }

    private static func intelligenceErrorCode(_ error: IntelligenceError) -> String {
        switch error {
        case .unavailable: "model_unavailable"
        case let .selection(failure): selectionFailureCode(failure)
        case .emptyDocument: "internal_fixture_empty"
        case .invalidFields: "internal_fixture_fields_invalid"
        case .bridgeUnavailable: "bridge_unavailable"
        case .bridgeInvalid: "bridge_invalid"
        case .generationTimedOut: "generation_timed_out"
        case .generationFailed: "generation_failed"
        case .contextOverflow: "context_overflow"
        case .malformedOutput: "malformed_output"
        case .ungroundedOutput: "ungrounded_output"
        case .cancelled: "cancelled"
        }
    }

    private static func selectionFailureCode(
        _ failure: LocalIntelligenceSelectionFailure
    ) -> String {
        switch failure {
        case .corruptReceipt: "selection_corrupt"
        case .providerUnavailable: "provider_unavailable"
        case .modelUnavailable: "model_unavailable"
        case .localityUnverified: "locality_unverified"
        case .localityBlocked: "locality_blocked"
        case .qualificationRequired: "qualification_required"
        case .acknowledgmentRequired: "acknowledgment_required"
        case .identityChanged: "identity_changed"
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

private enum MissingIntelligenceManagerError: Error {
    case unavailable
}

private struct IntelligenceModelsResponse: Encodable {
    let models: [IntelligenceModelResponse]
}

private struct IntelligenceModelResponse: Encodable {
    let provider: String
    let model: String
    let fingerprint: String?
    let harnessVersion: String?
    let displayName: String
    let locality: String
    let localityReason: String
    let qualification: String
    let available: Bool
    let selected: Bool

    init(_ descriptor: LocalModelDescriptor) {
        provider = descriptor.identity.provider.rawValue
        model = descriptor.identity.model
        fingerprint = descriptor.identity.fingerprint
        harnessVersion = descriptor.identity.harnessVersion
        displayName = descriptor.displayName
        locality = descriptor.locality.rawValue
        localityReason = descriptor.localityReason
        qualification = descriptor.qualification.rawValue
        available = descriptor.available
        selected = descriptor.selected
    }

    static let textHeader = "PROVIDER\tMODEL\tFINGERPRINT\tHARNESS_VERSION\tDISPLAY_NAME\tLOCALITY\tLOCALITY_REASON\tQUALIFICATION\tAVAILABLE\tSELECTED\n"

    var textLine: String {
        [
            provider, model, fingerprint ?? "-", harnessVersion ?? "-", displayName,
            locality, localityReason, qualification, String(available), String(selected)
        ].map(intelligenceTextField).joined(separator: "\t") + "\n"
    }
}

private struct IntelligenceQualificationResponse: Encodable {
    let provider: String
    let model: String
    let fingerprint: String?
    let harnessVersion: String?
    let status: String
    let failures: [String]
    let qualifiedAt: String?
    let qualificationPolicyVersion: Int?
    let fixtureVersion: Int?
    let passedActions: [String]

    init(
        descriptor: LocalModelDescriptor,
        outcome: LocalModelQualificationOutcome
    ) {
        provider = descriptor.identity.provider.rawValue
        model = descriptor.identity.model
        fingerprint = descriptor.identity.fingerprint
        harnessVersion = descriptor.identity.harnessVersion
        status = outcome.status.rawValue
        failures = outcome.failures
        qualifiedAt = outcome.receipt.map { intelligenceTimestamp($0.qualifiedAt) }
        qualificationPolicyVersion = outcome.receipt?.policyVersion
        fixtureVersion = outcome.receipt?.fixtureVersion
        passedActions = outcome.receipt?.passedActions.map(\.rawValue).sorted() ?? []
    }

    var text: String {
        """
        Provider: \(intelligenceTextField(intelligenceProviderDisplayName(LocalModelProviderID(rawValue: provider))))
        Model: \(intelligenceTextField(model))
        Fingerprint: \(intelligenceTextField(fingerprint ?? "-"))
        Harness version: \(intelligenceTextField(harnessVersion ?? "-"))
        Status: \(intelligenceTextField(status))
        Failures: \(intelligenceTextField(failures.isEmpty ? "none" : failures.joined(separator: ", ")))
        Qualified at: \(intelligenceTextField(qualifiedAt ?? "-"))
        Qualification policy: \(qualificationPolicyVersion.map(String.init) ?? "-")
        Fixture version: \(fixtureVersion.map(String.init) ?? "-")
        Passed actions: \(intelligenceTextField(passedActions.isEmpty ? "-" : passedActions.joined(separator: ", ")))
        """ + "\n"
    }
}

private struct IntelligenceResetResponse: Encodable {
    let state: String
}

private struct IntelligenceStatusResponse: Encodable {
    let state: String
    let resetAt: String?
    let provider: String?
    let model: String?
    let fingerprint: String?
    let harnessVersion: String?
    let qualification: String?
    let qualifiedAt: String?
    let qualificationPolicyVersion: Int?
    let fixtureVersion: Int?
    let acknowledgment: String?
    let acknowledgedAt: String?
    let acknowledgmentPolicyVersion: Int?
    let failure: String?

    init(_ selectionState: LocalIntelligenceSelectionState) {
        switch selectionState {
        case .none:
            self.init(state: "none")
        case let .reset(at):
            self.init(state: "reset", resetAt: intelligenceTimestamp(at))
        case .selected(.appleSystemDefault):
            self.init(
                state: "selected",
                identity: .appleSystemDefault,
                qualification: "not_required",
                acknowledgment: "not_required"
            )
        case let .selected(.external(identity, qualification, acknowledgment)):
            let qualificationCurrent = qualification.policyVersion ==
                LocalModelQualificationReceipt.currentPolicyVersion &&
                qualification.fixtureVersion ==
                LocalModelQualificationReceipt.currentFixtureVersion &&
                qualification.identity == identity &&
                qualification.passedActions == Set(LocalIntelligenceAction.allCases)
            let acknowledgmentCurrent = acknowledgment.policyVersion ==
                ExternalLocalModelAcknowledgment.currentPolicyVersion &&
                acknowledgment.identity == identity
            self.init(
                state: "selected",
                resetAt: nil,
                provider: identity.provider.rawValue,
                model: identity.model,
                fingerprint: identity.fingerprint,
                harnessVersion: identity.harnessVersion,
                qualification: qualificationCurrent ? "passed" : "stale",
                qualifiedAt: intelligenceTimestamp(qualification.qualifiedAt),
                qualificationPolicyVersion: qualification.policyVersion,
                fixtureVersion: qualification.fixtureVersion,
                acknowledgment: acknowledgmentCurrent ? "current" : "stale",
                acknowledgedAt: intelligenceTimestamp(acknowledgment.acceptedAt),
                acknowledgmentPolicyVersion: acknowledgment.policyVersion,
                failure: nil
            )
        case let .invalid(selectionFailure):
            let identity = Self.identity(from: selectionFailure)
            let provider = if case let .providerUnavailable(value) = selectionFailure {
                value.rawValue
            } else {
                identity?.provider.rawValue
            }
            self.init(
                state: "invalid",
                resetAt: nil,
                provider: provider,
                model: identity?.model,
                fingerprint: identity?.fingerprint,
                harnessVersion: identity?.harnessVersion,
                qualification: nil,
                qualifiedAt: nil,
                qualificationPolicyVersion: nil,
                fixtureVersion: nil,
                acknowledgment: nil,
                acknowledgedAt: nil,
                acknowledgmentPolicyVersion: nil,
                failure: Self.failureCode(selectionFailure)
            )
        }
    }

    private init(
        state: String,
        identity: LocalModelIdentity? = nil,
        qualification: String? = nil,
        acknowledgment: String? = nil,
        resetAt: String? = nil
    ) {
        self.init(
            state: state,
            resetAt: resetAt,
            provider: identity?.provider.rawValue,
            model: identity?.model,
            fingerprint: identity?.fingerprint,
            harnessVersion: identity?.harnessVersion,
            qualification: qualification,
            qualifiedAt: nil,
            qualificationPolicyVersion: nil,
            fixtureVersion: nil,
            acknowledgment: acknowledgment,
            acknowledgedAt: nil,
            acknowledgmentPolicyVersion: nil,
            failure: nil
        )
    }

    private init(
        state: String,
        resetAt: String?,
        provider: String?,
        model: String?,
        fingerprint: String?,
        harnessVersion: String?,
        qualification: String?,
        qualifiedAt: String?,
        qualificationPolicyVersion: Int?,
        fixtureVersion: Int?,
        acknowledgment: String?,
        acknowledgedAt: String?,
        acknowledgmentPolicyVersion: Int?,
        failure: String?
    ) {
        self.state = state
        self.resetAt = resetAt
        self.provider = provider
        self.model = model
        self.fingerprint = fingerprint
        self.harnessVersion = harnessVersion
        self.qualification = qualification
        self.qualifiedAt = qualifiedAt
        self.qualificationPolicyVersion = qualificationPolicyVersion
        self.fixtureVersion = fixtureVersion
        self.acknowledgment = acknowledgment
        self.acknowledgedAt = acknowledgedAt
        self.acknowledgmentPolicyVersion = acknowledgmentPolicyVersion
        self.failure = failure
    }

    var text: String {
        guard state != "none" else { return "State: none\n" }
        var lines = ["State: \(intelligenceTextField(state))"]
        if let resetAt { lines.append("Reset at: \(intelligenceTextField(resetAt))") }
        if let provider {
            lines.append("Provider: \(intelligenceTextField(intelligenceProviderDisplayName(LocalModelProviderID(rawValue: provider))))")
        }
        if let model { lines.append("Model: \(intelligenceTextField(model))") }
        if let fingerprint { lines.append("Fingerprint: \(intelligenceTextField(fingerprint))") }
        if let harnessVersion { lines.append("Harness version: \(intelligenceTextField(harnessVersion))") }
        if let qualification { lines.append("Qualification: \(intelligenceTextField(qualification))") }
        if let qualifiedAt { lines.append("Qualified at: \(intelligenceTextField(qualifiedAt))") }
        if let qualificationPolicyVersion {
            lines.append("Qualification policy: \(qualificationPolicyVersion)")
        }
        if let fixtureVersion { lines.append("Fixture version: \(fixtureVersion)") }
        if let acknowledgment { lines.append("Acknowledgment: \(intelligenceTextField(acknowledgment))") }
        if let acknowledgedAt { lines.append("Acknowledged at: \(intelligenceTextField(acknowledgedAt))") }
        if let acknowledgmentPolicyVersion {
            lines.append("Acknowledgment policy: \(acknowledgmentPolicyVersion)")
        }
        if let failure { lines.append("Failure: \(intelligenceTextField(failure))") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func identity(
        from failure: LocalIntelligenceSelectionFailure
    ) -> LocalModelIdentity? {
        switch failure {
        case .corruptReceipt, .providerUnavailable:
            nil
        case let .modelUnavailable(identity), let .localityUnverified(identity),
             let .localityBlocked(identity), let .qualificationRequired(identity),
             let .acknowledgmentRequired(identity):
            identity
        case let .identityChanged(expected, _):
            expected
        }
    }

    private static func failureCode(_ failure: LocalIntelligenceSelectionFailure) -> String {
        switch failure {
        case .corruptReceipt: "selection_corrupt"
        case .providerUnavailable: "provider_unavailable"
        case .modelUnavailable: "model_unavailable"
        case .localityUnverified: "locality_unverified"
        case .localityBlocked: "locality_blocked"
        case .qualificationRequired: "qualification_required"
        case .acknowledgmentRequired: "acknowledgment_required"
        case .identityChanged: "identity_changed"
        }
    }
}

private func intelligenceProviderDisplayName(_ provider: LocalModelProviderID?) -> String {
    switch provider {
    case .appleFoundationModels: "Apple Foundation Models"
    case .ollama: "Ollama"
    case .lmStudio: "LM Studio"
    case nil: "Unknown"
    }
}

private func intelligenceTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func intelligenceTextField(_ value: String) -> String {
    value.unicodeScalars.reduce(into: "") { result, scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            result.append(" ")
        default:
            result.unicodeScalars.append(scalar)
        }
    }
}

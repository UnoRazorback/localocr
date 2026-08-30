import Foundation
import LocalOCRIntelligence
import Observation

public enum AgentConnectionReceiptStatus: Sendable, Equatable {
    case loading
    case current
    case required
}

public enum AgentClientGuideDiscoveryState: Sendable, Equatable {
    case idle
    case discovering
    case unavailable
    case available
}

public enum AgentClientGuideState: Sendable, Equatable {
    case unavailable
    case inspecting
    case disconnected
    case connected(helperPath: String)
    case conflict
    case failed
}

public enum GenericAgentClientMode: Sendable, Equatable {
    case copyOnly
}

@MainActor
@Observable
public final class AgentConnectionGuideModel {
    public static let externalDataDisclosure = """
    LocalOCR and Apple Foundation Models process documents locally on this Mac,
    and LocalOCR does not upload them. When you connect LocalOCR to an agent
    through MCP, that MCP client or its AI provider may send filenames, paths,
    document text, summaries, extracted fields, and tool results to an outside
    service. Transmission, retention, model training, and other handling are
    controlled by the agent and provider, not LocalOCR. Review their privacy and
    data policies, and only continue if you are authorized to share the data.
    """

    private static let approvedExternalProviderRiskAcknowledgment = "I understand that my MCP client or agent may transmit LocalOCR inputs and results to an outside provider."
    private static let approvedDocumentToolAccessAcknowledgment = "I confirm that I am authorized to share this data and choose to enable LocalOCR MCP document tools."

    public let helperPath: String
    public let codexCommands: String
    public let codexRemovalCommand = "codex mcp remove localocr"
    public let codexScopeGuidance = """
    Codex has no project or user scope option for MCP add/remove. The installed CLI stores this server in the Codex host's user configuration, shared by Codex CLI, the IDE extension, and the desktop app on that host. Use codex mcp list or /mcp to inspect it. Run the removal command separately to disconnect it.
    """
    public let claudeCodeCommands: String
    public let claudeCodeRemovalCommand = "claude mcp remove --scope local localocr"
    public let claudeCodeScopeGuidance = """
    Claude Code defaults to local scope for the current project; the command makes that scope explicit. Use --scope user only when you intentionally want LocalOCR across projects. Use claude mcp list or /mcp to inspect it, and remove it from the same scope where you added it.
    """
    public let genericStdioJSON: String
    public let localIntelligenceTools = [
        "summarize_document",
        "organize_document",
        "extract_document_fields",
    ]
    public let ocrAndPDFTools = [
        "get_pdf_page_count",
        "inspect_pdf",
        "ocr_pdf",
        "ocr_pdf_batch",
        "ocr_image",
        "make_searchable_pdf",
    ]
    public let localIntelligenceRequirements = """
    summarize_document, organize_document, and extract_document_fields use Apple Foundation Models through SystemLanguageModel.default and identify that model in each result. They require macOS 26 or later, an eligible Mac, Apple Intelligence enabled, the on-device model ready, and a currently supported Apple Intelligence language. Apple does not expose the installed system model's specific name or version. The six OCR and PDF tools remain available when Local Intelligence is unavailable.
    """
    public let safeExamplePrompts = [
        "Inspect /path/to/test-invoice.pdf and report only its page count and whether it already has searchable text.",
        "OCR /path/to/test-scan.png and return only the recognized text.",
        "Summarize /path/to/test-letter.pdf in three factual bullets using Local Intelligence.",
    ]
    public let genericClientMode: GenericAgentClientMode = .copyOnly
    public let restartGuidance = "After a change, restart or reload normally if your agent does not refresh its MCP list. LocalOCR will not close the agent for you."
    public var disclosure: String { Self.externalDataDisclosure }
    public var externalProviderRiskAcknowledgment: String {
        Self.approvedExternalProviderRiskAcknowledgment
    }
    public var documentToolAccessAcknowledgment: String {
        Self.approvedDocumentToolAccessAcknowledgment
    }

    public var externalProviderRiskAccepted = false
    public var documentToolAccessAccepted = false
    public private(set) var receiptStatus: AgentConnectionReceiptStatus = .loading
    public private(set) var isUpdatingConsent = false
    public private(set) var consentError: String?
    public private(set) var discoveryState: AgentClientGuideDiscoveryState = .idle
    public private(set) var detectedClients: [AgentClientInstallation] = []
    public var selectedClientID: String?
    public var claudeScope: ClaudeMCPConnectionScope?
    public var connectionChangeConfirmed = false
    public private(set) var isChangingConnection = false
    public private(set) var connectionError: String?

    private var clientStates: [String: AgentClientGuideState] = [:]

    public var canAccept: Bool {
        externalProviderRiskAccepted
            && documentToolAccessAccepted
            && !isUpdatingConsent
    }

    public var selectedClient: AgentClientInstallation? {
        detectedClients.first { $0.id == selectedClientID }
    }

    public var canConnect: Bool {
        guard receiptStatus == .current,
              connectionChangeConfirmed,
              !isChangingConnection,
              let selectedClient,
              clientState(for: selectedClient) == .disconnected
        else {
            return false
        }
        return selectedClient.kind != .claudeCode || claudeScope != nil
    }

    public var canDisconnect: Bool {
        guard connectionChangeConfirmed,
              !isChangingConnection,
              let selectedClient
        else {
            return false
        }
        let state = clientState(for: selectedClient)
        guard state.isRegistered else { return false }
        return selectedClient.kind != .claudeCode || claudeScope != nil
    }

    @ObservationIgnored private let consentStore: any ExternalDataConsentStoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let discoverClients: () -> AgentClientDiscoveryResult
    @ObservationIgnored private let runCommand: (AgentClientCommandSpec) async throws -> AgentClientCommandResult

    public init(
        bundleURL: URL,
        consentStore: any ExternalDataConsentStoring,
        now: @escaping @Sendable () -> Date = Date.init,
        discoverClients: @escaping () -> AgentClientDiscoveryResult = {
            AgentClientDiscoveryResult(installations: [], rejections: [])
        },
        runCommand: @escaping (AgentClientCommandSpec) async throws -> AgentClientCommandResult = { _ in
            throw AgentClientCommandRunnerError.launchFailed
        }
    ) {
        let helperPath = bundleURL
            .appendingPathComponent("Contents/Helpers/localocr-mcp")
            .path
        self.helperPath = helperPath
        self.consentStore = consentStore
        self.now = now
        self.discoverClients = discoverClients
        self.runCommand = runCommand

        let shellPath = Self.shellQuote(helperPath)
        codexCommands = """
        codex mcp add localocr -- \(shellPath)
        codex mcp list
        """
        claudeCodeCommands = """
        claude mcp add --transport stdio --scope local localocr -- \(shellPath)
        claude mcp list
        """
        genericStdioJSON = Self.makeGenericStdioJSON(helperPath: helperPath)
    }

    public convenience init(bundleURL: URL = Bundle.main.bundleURL) {
        let runner = AgentClientCommandRunner()
        self.init(
            bundleURL: bundleURL,
            consentStore: ExternalDataConsentStore(),
            discoverClients: {
                AgentClientDiscovery().discoverInstalledClients()
            },
            runCommand: { spec in
                try await runner.run(spec)
            }
        )
    }

    public func resetSessionAcknowledgments() {
        externalProviderRiskAccepted = false
        documentToolAccessAccepted = false
        consentError = nil
    }

    public func prepareForPresentation() async {
        resetSessionAcknowledgments()
        await refreshReceiptStatus()
        await refreshClients()
    }

    public func clientState(for installation: AgentClientInstallation) -> AgentClientGuideState {
        clientStates[installation.id] ?? .unavailable
    }

    public func refreshClients() async {
        guard discoveryState != .discovering, !isChangingConnection else { return }
        discoveryState = .discovering
        connectionError = nil
        let result = discoverClients()
        detectedClients = result.installations
        let validIDs = Set(detectedClients.map(\.id))
        clientStates = clientStates.filter { validIDs.contains($0.key) }

        guard !detectedClients.isEmpty else {
            selectedClientID = nil
            discoveryState = .unavailable
            return
        }

        if selectedClient == nil {
            selectedClientID = detectedClients.first?.id
        }
        for installation in detectedClients {
            await inspect(installation)
        }
        discoveryState = .available
    }

    public func connectSelectedClient() async throws {
        guard canConnect, let installation = selectedClient else { return }
        isChangingConnection = true
        connectionError = nil
        clientStates[installation.id] = .inspecting
        defer {
            isChangingConnection = false
            connectionChangeConfirmed = false
        }

        do {
            let scope = claudeScope ?? .local
            _ = try await runCommand(AgentClientCommandFactory.connect(
                installation,
                helperURL: URL(fileURLWithPath: helperPath),
                claudeScope: scope
            ))
            await inspect(installation)
        } catch {
            clientStates[installation.id] = .failed
            connectionError = Self.safeConnectionError(for: error)
            throw error
        }
    }

    public func disconnectSelectedClient() async throws {
        guard canDisconnect, let installation = selectedClient else { return }
        isChangingConnection = true
        connectionError = nil
        clientStates[installation.id] = .inspecting
        defer {
            isChangingConnection = false
            connectionChangeConfirmed = false
        }

        do {
            _ = try await runCommand(AgentClientCommandFactory.disconnect(
                installation,
                claudeScope: claudeScope ?? .local
            ))
            await inspect(installation)
        } catch {
            clientStates[installation.id] = .failed
            connectionError = Self.safeConnectionError(for: error)
            throw error
        }
    }

    public func refreshReceiptStatus() async {
        receiptStatus = .loading
        switch await consentStore.status() {
        case .current:
            receiptStatus = .current
        case .required:
            receiptStatus = .required
        }
    }

    public func accept() async throws {
        guard canAccept else { return }
        isUpdatingConsent = true
        consentError = nil
        defer { isUpdatingConsent = false }
        do {
            try await consentStore.acceptBothStatements(at: now())
            await refreshReceiptStatus()
        } catch {
            consentError = "LocalOCR could not save the acknowledgment. Please try again."
            throw error
        }
    }

    public func revoke() async throws {
        isUpdatingConsent = true
        consentError = nil
        defer { isUpdatingConsent = false }
        do {
            try await consentStore.revoke()
            resetSessionAcknowledgments()
            await refreshReceiptStatus()
        } catch {
            consentError = "LocalOCR could not revoke the acknowledgment. Please try again."
            throw error
        }
    }

    private func inspect(_ installation: AgentClientInstallation) async {
        clientStates[installation.id] = .inspecting
        do {
            let result = try await runCommand(AgentClientCommandFactory.inspect(installation))
            let output = result.stdoutString + "\n" + result.stderrString
            if output.contains(helperPath) {
                clientStates[installation.id] = .connected(helperPath: helperPath)
            } else {
                clientStates[installation.id] = .conflict
            }
        } catch AgentClientCommandRunnerError.exited {
            clientStates[installation.id] = .disconnected
        } catch is CancellationError {
            clientStates[installation.id] = .failed
            connectionError = "The client check was cancelled."
        } catch {
            clientStates[installation.id] = .failed
            connectionError = Self.safeConnectionError(for: error)
        }
    }

    private static func safeConnectionError(for error: Error) -> String {
        if let runnerError = error as? AgentClientCommandRunnerError {
            return runnerError.localizedDescription
        }
        return "LocalOCR could not check or update the selected agent client."
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func makeGenericStdioJSON(helperPath: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["command": helperPath, "args": []],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

private extension AgentClientGuideState {
    var isRegistered: Bool {
        switch self {
        case .connected, .conflict:
            true
        case .unavailable, .inspecting, .disconnected, .failed:
            false
        }
    }
}

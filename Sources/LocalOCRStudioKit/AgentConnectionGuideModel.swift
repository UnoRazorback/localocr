import Foundation
import LocalOCRIntelligence
import Observation

public enum AgentConnectionReceiptStatus: Sendable, Equatable {
    case loading
    case current
    case required
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
    summarize_document, organize_document, and extract_document_fields require Apple Foundation Models: macOS 26 or later, an eligible Mac, Apple Intelligence enabled, the on-device model ready, and a currently supported Apple Intelligence language. The six OCR and PDF tools remain available when Local Intelligence is unavailable.
    """
    public let safeExamplePrompts = [
        "Inspect /Users/Shared/LocalOCR Test Files/test-invoice.pdf and report only its page count and whether it already has searchable text.",
        "OCR /Users/Shared/LocalOCR Test Files/test-scan.png and return only the recognized text.",
        "Summarize /Users/Shared/LocalOCR Test Files/test-letter.pdf in three factual bullets using Local Intelligence.",
    ]
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

    public var canAccept: Bool {
        externalProviderRiskAccepted
            && documentToolAccessAccepted
            && !isUpdatingConsent
    }

    @ObservationIgnored private let consentStore: any ExternalDataConsentStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        bundleURL: URL,
        consentStore: any ExternalDataConsentStoring,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let helperPath = bundleURL
            .appendingPathComponent("Contents/Helpers/localocr-mcp")
            .path
        self.helperPath = helperPath
        self.consentStore = consentStore
        self.now = now

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
        self.init(
            bundleURL: bundleURL,
            consentStore: ExternalDataConsentStore()
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

import Foundation
import LocalOCRIntelligence
@testable import LocalOCRStudioKit
import Testing

@MainActor
@Suite("Agent connection guide model")
struct AgentConnectionGuideModelTests {
    @Test("helper path and client snippets use the injected app bundle path safely")
    func dynamicHelperPathAndSnippets() throws {
        let bundleURL = URL(
            fileURLWithPath: "/tmp/Test User's Apps/LocalOCR Studio.app",
            isDirectory: true
        )
        let store = GuideConsentStore()
        let model = AgentConnectionGuideModel(bundleURL: bundleURL, consentStore: store)
        let helper = "/tmp/Test User's Apps/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"

        #expect(model.helperPath == helper)
        #expect(model.codexCommands == """
        codex mcp add localocr -- '/tmp/Test User'\"'\"'s Apps/LocalOCR Studio.app/Contents/Helpers/localocr-mcp'
        codex mcp list
        """)
        #expect(model.codexRemovalCommand == "codex mcp remove localocr")
        #expect(model.codexScopeGuidance == """
        Codex has no project or user scope option for MCP add/remove. The installed CLI stores this server in the Codex host's user configuration, shared by Codex CLI, the IDE extension, and the desktop app on that host. Use codex mcp list or /mcp to inspect it. Run the removal command separately to disconnect it.
        """)
        #expect(model.claudeCodeCommands == """
        claude mcp add --transport stdio --scope local localocr -- '/tmp/Test User'\"'\"'s Apps/LocalOCR Studio.app/Contents/Helpers/localocr-mcp'
        claude mcp list
        """)
        #expect(model.claudeCodeRemovalCommand == "claude mcp remove --scope local localocr")
        #expect(model.claudeCodeScopeGuidance == """
        Claude Code defaults to local scope for the current project; the command makes that scope explicit. Use --scope user only when you intentionally want LocalOCR across projects. Use claude mcp list or /mcp to inspect it, and remove it from the same scope where you added it.
        """)

        let json = try #require(model.genericStdioJSON.data(using: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        #expect(object["command"] as? String == helper)
        #expect(object["args"] as? [String] == [])
        #expect(!model.codexCommands.contains("/Applications/"))
        #expect(!model.claudeCodeCommands.contains("/Users/scott"))
    }

    @Test("guide distinguishes Foundation Models tools and availability from OCR")
    func intelligenceRequirementsAndOCRFallback() {
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore()
        )

        #expect(model.localIntelligenceTools == [
            "summarize_document",
            "organize_document",
            "extract_document_fields",
        ])
        #expect(model.ocrAndPDFTools == [
            "get_pdf_page_count",
            "inspect_pdf",
            "ocr_pdf",
            "ocr_pdf_batch",
            "ocr_image",
            "make_searchable_pdf",
        ])
        #expect(model.localIntelligenceRequirements == """
        summarize_document, organize_document, and extract_document_fields require Apple Foundation Models: macOS 26 or later, an eligible Mac, Apple Intelligence enabled, the on-device model ready, and a currently supported Apple Intelligence language. The six OCR and PDF tools remain available when Local Intelligence is unavailable.
        """)
    }

    @Test("safe examples use explicit local paths and narrow document tasks")
    func safeExamplesAreConcreteAndNarrow() {
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore()
        )

        #expect(model.safeExamplePrompts == [
            "Inspect /path/to/test-invoice.pdf and report only its page count and whether it already has searchable text.",
            "OCR /path/to/test-scan.png and return only the recognized text.",
            "Summarize /path/to/test-letter.pdf in three factual bullets using Local Intelligence.",
        ])
    }

    @Test("guide presents the approved disclosure and both acknowledgments verbatim")
    func exactConsentWording() {
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore()
        )

        #expect(model.disclosure == """
        LocalOCR and Apple Foundation Models process documents locally on this Mac,
        and LocalOCR does not upload them. When you connect LocalOCR to an agent
        through MCP, that MCP client or its AI provider may send filenames, paths,
        document text, summaries, extracted fields, and tool results to an outside
        service. Transmission, retention, model training, and other handling are
        controlled by the agent and provider, not LocalOCR. Review their privacy and
        data policies, and only continue if you are authorized to share the data.
        """)
        #expect(
            model.externalProviderRiskAcknowledgment
                == "I understand that my MCP client or agent may transmit LocalOCR inputs and results to an outside provider."
        )
        #expect(
            model.documentToolAccessAcknowledgment
                == "I confirm that I am authorized to share this data and choose to enable LocalOCR MCP document tools."
        )
    }

    @Test("accept remains disabled until both current-session acknowledgments are checked")
    func bothAcknowledgmentsRequired() async throws {
        let store = GuideConsentStore()
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: store,
            now: { Date(timeIntervalSince1970: 1_777_777_777) }
        )

        await model.prepareForPresentation()
        #expect(model.externalProviderRiskAccepted == false)
        #expect(model.documentToolAccessAccepted == false)
        #expect(model.canAccept == false)
        try await model.accept()
        #expect(await store.acceptedDates.isEmpty)

        model.externalProviderRiskAccepted = true
        #expect(model.canAccept == false)
        try await model.accept()
        #expect(await store.acceptedDates.isEmpty)
        model.documentToolAccessAccepted = true
        #expect(model.canAccept == true)

        try await model.accept()
        #expect(await store.acceptedDates == [Date(timeIntervalSince1970: 1_777_777_777)])
        #expect(model.receiptStatus == .current)
    }

    @Test("opening the guide resets acknowledgments and refreshes receipt status")
    func openingResetsControls() async {
        let receipt = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: Date(timeIntervalSince1970: 100),
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        let store = GuideConsentStore(status: .current(receipt))
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: store
        )
        model.externalProviderRiskAccepted = true
        model.documentToolAccessAccepted = true

        await model.prepareForPresentation()

        #expect(model.externalProviderRiskAccepted == false)
        #expect(model.documentToolAccessAccepted == false)
        #expect(model.receiptStatus == .current)
    }

    @Test("revoking changes the informational status without touching client configuration")
    func revokeAndNoClientConfigurationMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConnectionGuideModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("client-config.json")
        try Data("do not change".utf8).write(to: sentinel)

        let receipt = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: Date(timeIntervalSince1970: 100),
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        let store = GuideConsentStore(status: .current(receipt))
        let model = AgentConnectionGuideModel(bundleURL: root, consentStore: store)

        _ = model.codexCommands
        _ = model.claudeCodeCommands
        _ = model.genericStdioJSON
        try await model.revoke()

        #expect(await store.revokeCount == 1)
        #expect(model.receiptStatus == .required)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "do not change")
    }
}

private actor GuideConsentStore: ExternalDataConsentStoring {
    private(set) var currentStatus: ExternalDataConsentStatus
    private(set) var acceptedDates: [Date] = []
    private(set) var revokeCount = 0

    init(status: ExternalDataConsentStatus = .required) {
        currentStatus = status
    }

    func status() async -> ExternalDataConsentStatus {
        currentStatus
    }

    func acceptBothStatements(at date: Date) async throws {
        acceptedDates.append(date)
        currentStatus = .current(ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: date,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        ))
    }

    func revoke() async throws {
        revokeCount += 1
        currentStatus = .required
    }
}

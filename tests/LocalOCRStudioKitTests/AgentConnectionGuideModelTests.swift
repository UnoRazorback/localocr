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
        summarize_document, organize_document, and extract_document_fields use Apple Foundation Models through SystemLanguageModel.default and identify that model in each result. They require macOS 26 or later, an eligible Mac, Apple Intelligence enabled, the on-device model ready, and a currently supported Apple Intelligence language. Apple does not expose the installed system model's specific name or version. The six OCR and PDF tools remain available when Local Intelligence is unavailable.
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

    @Test("inspect distinguishes this app helper from another localocr registration")
    func inspectConnectedConflictAndUnavailableStates() async {
        let helper = "/tmp/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
        let codex = guideInstallation(.codex, path: "/tmp/clients/codex")
        let claude = guideInstallation(.claudeCode, path: "/tmp/clients/claude")
        let executor = GuideCommandExecutor(responses: [
            .success(commandResult(stdout: "command: \(helper)")),
            .success(commandResult(stdout: "command: /Applications/Old LocalOCR.app/Contents/Helpers/localocr-mcp")),
        ])
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore(),
            discoverClients: {
                AgentClientDiscoveryResult(installations: [codex, claude], rejections: [])
            },
            runCommand: { try await executor.run($0) }
        )

        await model.refreshClients()

        #expect(model.discoveryState == .available)
        #expect(model.clientState(for: codex) == .connected(helperPath: helper))
        #expect(model.clientState(for: claude) == .conflict)

        let unavailable = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore(),
            discoverClients: { AgentClientDiscoveryResult(installations: [], rejections: []) }
        )
        await unavailable.refreshClients()
        #expect(unavailable.discoveryState == .unavailable)
    }

    @Test("connect requires current acknowledgment selection scope and final confirmation")
    func connectGatesAndRefreshesExactSelection() async throws {
        let receipt = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: Date(timeIntervalSince1970: 100),
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        let claude = guideInstallation(.claudeCode, path: "/tmp/clients/claude")
        let helper = "/tmp/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
        let executor = GuideCommandExecutor(responses: [
            .failure(.exited(status: 1)),
            .success(commandResult()),
            .success(commandResult(stdout: "command: \(helper)")),
        ])
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore(status: .current(receipt)),
            discoverClients: {
                AgentClientDiscoveryResult(installations: [claude], rejections: [])
            },
            runCommand: { try await executor.run($0) }
        )
        await model.prepareForPresentation()
        model.selectedClientID = claude.id

        #expect(model.canConnect == false)
        try await model.connectSelectedClient()
        #expect(await executor.commands.count == 1)

        model.claudeScope = .user
        #expect(model.canConnect == false)
        model.connectionChangeConfirmed = true
        #expect(model.canConnect == true)

        try await model.connectSelectedClient()

        #expect(model.clientState(for: claude) == .connected(helperPath: helper))
        let commands = await executor.commands
        #expect(commands[1].arguments == [
            "mcp", "add", "--transport", "stdio", "--scope", "user", "localocr", "--", helper,
        ])
        #expect(model.connectionChangeConfirmed == false)
    }

    @Test("disconnect removes only the explicitly selected client registration")
    func disconnectUsesSelectedClientAndScope() async throws {
        let codex = guideInstallation(.codex, path: "/tmp/clients/codex")
        let claude = guideInstallation(.claudeCode, path: "/tmp/clients/claude")
        let helper = "/tmp/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
        let executor = GuideCommandExecutor(responses: [
            .success(commandResult(stdout: "command: \(helper)")),
            .success(commandResult(stdout: "command: \(helper)")),
            .success(commandResult()),
            .failure(.exited(status: 1)),
        ])
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore(),
            discoverClients: {
                AgentClientDiscoveryResult(installations: [codex, claude], rejections: [])
            },
            runCommand: { try await executor.run($0) }
        )
        await model.refreshClients()
        model.selectedClientID = claude.id
        model.claudeScope = .local
        model.connectionChangeConfirmed = true

        try await model.disconnectSelectedClient()

        let commands = await executor.commands
        #expect(commands[2].executableURL == claude.executableURL)
        #expect(commands[2].arguments == ["mcp", "remove", "--scope", "local", "localocr"])
        #expect(model.clientState(for: claude) == .disconnected)
        #expect(model.clientState(for: codex) == .connected(helperPath: helper))
    }

    @Test("generic clients remain copy only and restart guidance never requests force quit")
    func genericAndRestartBoundary() {
        let model = AgentConnectionGuideModel(
            bundleURL: URL(fileURLWithPath: "/tmp/LocalOCR Studio.app"),
            consentStore: GuideConsentStore()
        )

        #expect(model.genericClientMode == .copyOnly)
        #expect(model.restartGuidance.contains("restart or reload normally"))
        #expect(!model.restartGuidance.localizedCaseInsensitiveContains("force quit"))
        #expect(!model.restartGuidance.localizedCaseInsensitiveContains("kill"))
    }
}

private func guideInstallation(_ kind: AgentClientKind, path: String) -> AgentClientInstallation {
    AgentClientInstallation(
        kind: kind,
        executableURL: URL(fileURLWithPath: path),
        displayName: kind.displayName
    )
}

private func commandResult(stdout: String = "", stderr: String = "") -> AgentClientCommandResult {
    AgentClientCommandResult(
        exitStatus: 0,
        stdout: Data(stdout.utf8),
        stderr: Data(stderr.utf8)
    )
}

private actor GuideCommandExecutor {
    private var responses: [Result<AgentClientCommandResult, AgentClientCommandRunnerError>]
    private(set) var commands: [AgentClientCommandSpec] = []

    init(responses: [Result<AgentClientCommandResult, AgentClientCommandRunnerError>]) {
        self.responses = responses
    }

    func run(_ command: AgentClientCommandSpec) throws -> AgentClientCommandResult {
        commands.append(command)
        guard !responses.isEmpty else { throw AgentClientCommandRunnerError.launchFailed }
        return try responses.removeFirst().get()
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

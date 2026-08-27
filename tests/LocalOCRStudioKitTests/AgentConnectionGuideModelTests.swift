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
        #expect(model.claudeCodeCommands == """
        claude mcp add --transport stdio localocr -- '/tmp/Test User'\"'\"'s Apps/LocalOCR Studio.app/Contents/Helpers/localocr-mcp'
        claude mcp list
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

@testable import LocalOCRStudioKit
import Testing

@Suite("Help Center model")
struct HelpCenterModelTests {
    @Test("ships the twelve approved offline help topics in navigation order")
    func approvedTopicInventory() {
        let model = HelpCenterModel(marketingVersion: "0.3.1", buildNumber: "4")

        #expect(model.topics.map(\.id) == [
            .gettingStarted,
            .singleDocument,
            .desktopBatch,
            .outputs,
            .localIntelligence,
            .appleFoundationModels,
            .localRuntimes,
            .agentConnection,
            .privacy,
            .troubleshooting,
            .faq,
            .version,
        ])
        #expect(model.topics.map(\.title) == [
            "Getting Started",
            "Single Document",
            "Desktop Batch",
            "Searchable PDFs and Saved Text",
            "Local Intelligence",
            "Apple Foundation Models",
            "Ollama and LM Studio",
            "Connect to Your Agent",
            "Privacy and Data Boundaries",
            "Troubleshooting",
            "FAQ",
            "Version and Build Information",
        ])
    }

    @Test("search matches titles body text and keywords without using a network index")
    func searchMatchesBundledContent() {
        let model = HelpCenterModel(marketingVersion: "0.3.1", buildNumber: "4")

        #expect(model.filteredTopics(matching: "numbered filename").map(\.id) == [.desktopBatch])
        #expect(model.filteredTopics(matching: "SystemLanguageModel.default").map(\.id) == [
            .appleFoundationModels,
        ])
        #expect(model.filteredTopics(matching: "mcp").map(\.id).contains(.agentConnection))
        #expect(model.filteredTopics(matching: "  ") == model.topics)
    }

    @Test("privacy help distinguishes LocalOCR processing from an external agent")
    func privacyBoundaryIsExplicit() throws {
        let model = HelpCenterModel(marketingVersion: "0.3.1", buildNumber: "4")
        let privacy = try #require(model.topic(id: .privacy))

        #expect(privacy.body.contains("Vision OCR stays on this Mac"))
        #expect(privacy.body.contains("MCP client or its AI provider may transmit"))
        #expect(privacy.body.contains("Local stdio does not guarantee provider privacy"))
        #expect(privacy.body.contains("original documents remain unchanged"))
    }

    @Test("version help renders the app supplied version and build")
    func versionAndBuildAreInjected() throws {
        let model = HelpCenterModel(marketingVersion: "0.3.1", buildNumber: "4")
        let version = try #require(model.topic(id: .version))

        #expect(version.body.contains("LocalOCR Studio 0.3.1 (4)"))
        #expect(version.body.contains("macOS 14 or later"))
        #expect(version.body.contains("Local Intelligence requires macOS 26 or later"))
    }

    @Test("unknown or blank bundle values render honest fallbacks")
    func versionFallbacks() throws {
        let model = HelpCenterModel(marketingVersion: "", buildNumber: nil)
        let version = try #require(model.topic(id: .version))

        #expect(version.body.contains("LocalOCR Studio Unknown (Unknown)"))
    }

    @Test("Help menu contract owns the three approved actions")
    func helpMenuContract() {
        #expect(HelpMenuContract.helpTitle == "LocalOCR Studio Help")
        #expect(HelpMenuContract.agentTitle == "Connect to Your Agent")
        #expect(HelpMenuContract.feedbackTitle == "Report Beta Feedback")
        #expect(
            HelpMenuContract.feedbackURL.absoluteString
                == "https://github.com/UnoRazorback/localocr/issues/new/choose"
        )
    }
}

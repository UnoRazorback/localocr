import Foundation

public enum HelpMenuContract {
    public static let helpTitle = "LocalOCR Studio Help"
    public static let agentTitle = "Connect to Your Agent"
    public static let feedbackTitle = "Report Beta Feedback"
    public static let feedbackURL = URL(
        string: "https://github.com/UnoRazorback/localocr/issues/new/choose"
    )!
}

public enum HelpTopicID: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted
    case singleDocument
    case desktopBatch
    case outputs
    case localIntelligence
    case appleFoundationModels
    case localRuntimes
    case agentConnection
    case privacy
    case troubleshooting
    case faq
    case version

    public var id: String { rawValue }
}

public struct HelpTopic: Identifiable, Equatable, Sendable {
    public let id: HelpTopicID
    public let title: String
    public let summary: String
    public let body: String
    public let keywords: [String]

    public init(
        id: HelpTopicID,
        title: String,
        summary: String,
        body: String,
        keywords: [String]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.body = body
        self.keywords = keywords
    }
}

public struct HelpCenterModel: Sendable {
    public let topics: [HelpTopic]

    public init(marketingVersion: String?, buildNumber: String?) {
        let version = Self.nonempty(marketingVersion) ?? "Unknown"
        let build = Self.nonempty(buildNumber) ?? "Unknown"
        topics = Self.makeTopics(version: version, build: build)
    }

    public init(bundle: Bundle = .main) {
        self.init(
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        )
    }

    public func topic(id: HelpTopicID) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    public func filteredTopics(matching query: String) -> [HelpTopic] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return topics }
        return topics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(normalized)
                || topic.summary.localizedCaseInsensitiveContains(normalized)
                || topic.body.localizedCaseInsensitiveContains(normalized)
                || topic.keywords.contains {
                    $0.localizedCaseInsensitiveContains(normalized)
                }
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func makeTopics(version: String, build: String) -> [HelpTopic] {
        [
            HelpTopic(
                id: .gettingStarted,
                title: "Getting Started",
                summary: "Open a PDF or image and let LocalOCR recognize it on this Mac.",
                body: """
                Drop one PDF or supported image into LocalOCR Studio, or select Open Document. Recognition begins after you choose the file. The default workflow handles one document at a time and keeps the original unchanged.

                Start with a non-sensitive sample. After recognition, review the displayed text before copying, saving, or creating a searchable PDF.
                """,
                keywords: ["open", "drop", "first document", "on device"]
            ),
            HelpTopic(
                id: .singleDocument,
                title: "Single Document",
                summary: "Recognize one PDF or image and review its text.",
                body: """
                LocalOCR preserves useful existing PDF text and recognizes only pages that need OCR unless an advanced tool explicitly requests otherwise. Images are recognized with Apple Vision.

                Select Process Another Document to return to the start screen. Saved outputs remain where you placed them; the in-app result is cleared for the next document.
                """,
                keywords: ["PDF", "image", "Vision", "Process Another Document"]
            ),
            HelpTopic(
                id: .desktopBatch,
                title: "Desktop Batch",
                summary: "Review a queue and process files sequentially.",
                body: """
                Select New Batch, add files or folders, choose an output folder, and review supported and skipped items before selecting Start Batch. LocalOCR processes the approved queue sequentially.

                PDFs create searchable-PDF copies and images create text files. Existing output names are preserved by choosing a unique numbered filename. You can cancel, retry failed items, reveal the output folder, or start a new batch.
                """,
                keywords: ["queue", "folder", "sequential", "retry", "numbered filename"]
            ),
            HelpTopic(
                id: .outputs,
                title: "Searchable PDFs and Saved Text",
                summary: "Create new outputs without replacing the source.",
                body: """
                Copy places recognized text on the clipboard. Save Text writes a plain-text file. Create Searchable PDF writes a new PDF with an invisible text layer while keeping the visible pages intact.

                Choose a destination different from the source. LocalOCR refuses to overwrite the input document and does not silently replace an existing output.
                """,
                keywords: ["Copy", "Save Text", "searchable PDF", "output"]
            ),
            HelpTopic(
                id: .localIntelligence,
                title: "Local Intelligence",
                summary: "Run optional grounded analysis after OCR.",
                body: """
                Local Intelligence can summarize, suggest a name and tags, or extract requested fields from recognized page text. Vision OCR remains authoritative. Analysis is separately labeled, temporary, and never renames, moves, or rewrites the source.

                The result card identifies the selected local provider and model. Each action runs independently. Batch processing remains OCR-only.
                """,
                keywords: ["summarize", "organize", "extract fields", "grounded"]
            ),
            HelpTopic(
                id: .appleFoundationModels,
                title: "Apple Foundation Models",
                summary: "Use Apple's system on-device language model when available.",
                body: """
                LocalOCR uses SystemLanguageModel.default. Apple chooses and updates the installed system model and does not expose a more specific public model name or version.

                This option requires macOS 26 or later, an eligible Mac, Apple Intelligence enabled, the model ready, and a supported language. LocalOCR does not use Private Cloud Compute or a cloud fallback.
                """,
                keywords: ["Apple Intelligence", "SystemLanguageModel.default", "macOS 26"]
            ),
            HelpTopic(
                id: .localRuntimes,
                title: "Ollama and LM Studio",
                summary: "Select a qualified model from a verified local runtime.",
                body: """
                LocalOCR can detect supported Ollama and LM Studio installations on this Mac. It tests exact model identity, locality, and grounded document behavior before selection.

                Remote, relayed, wildcard, and locality-ambiguous endpoints are refused. LocalOCR never silently switches providers. Choosing an external local runtime requires an explicit acknowledgment for that provider and model.
                """,
                keywords: ["Ollama", "LM Studio", "loopback", "qualification", "model selection"]
            ),
            HelpTopic(
                id: .agentConnection,
                title: "Connect to Your Agent",
                summary: "Connect the bundled local stdio MCP helper to an agent.",
                body: """
                Open Connect to Your Agent from the Help menu. LocalOCR derives the MCP helper path from the running app and provides Codex, Claude Code, and generic stdio instructions.

                Connecting an agent is optional. Review and accept the external-data acknowledgment before enabling document tools. Restart or reload the client normally after configuration; LocalOCR never force-quits an agent.
                """,
                keywords: ["MCP", "Codex", "Claude", "stdio", "helper"]
            ),
            HelpTopic(
                id: .privacy,
                title: "Privacy and Data Boundaries",
                summary: "Understand what remains local and what an agent may share.",
                body: """
                Vision OCR stays on this Mac. LocalOCR does not upload source documents, recognized text, file paths, or outputs, and original documents remain unchanged.

                When MCP is connected, the MCP client or its AI provider may transmit filenames, paths, text, summaries, extracted fields, and tool results. Local stdio does not guarantee provider privacy. Review the client's current privacy and retention terms and use only data you are authorized to share.
                """,
                keywords: ["privacy", "data", "cloud", "retention", "consent"]
            ),
            HelpTopic(
                id: .troubleshooting,
                title: "Troubleshooting",
                summary: "Resolve common document, model, permission, and connection problems.",
                body: """
                If a document will not open, confirm it is a supported PDF or ImageIO image and that macOS grants LocalOCR access to its folder. Keep the original and report the exact error without posting sensitive content publicly.

                If Local Intelligence is unavailable, check the selected provider and its readiness. If an agent cannot see LocalOCR, inspect the exact helper path, acknowledgment status, client scope, and filesystem permissions, then reload the client normally.
                """,
                keywords: ["error", "permission", "damaged", "unavailable", "reload"]
            ),
            HelpTopic(
                id: .faq,
                title: "FAQ",
                summary: "Answers to common LocalOCR questions.",
                body: """
                Does LocalOCR replace my original? No. It writes new outputs.

                Does LocalOCR require the cloud? No. OCR is local. Optional MCP clients have their own separate data practices.

                Can batch analysis use Local Intelligence? Not in this beta; desktop batch is OCR-only.

                Can I use another local model? Yes, after LocalOCR detects and qualifies a supported Ollama or LM Studio model and you explicitly select it.
                """,
                keywords: ["questions", "original", "cloud", "batch", "other model"]
            ),
            HelpTopic(
                id: .version,
                title: "Version and Build Information",
                summary: "Identify this LocalOCR Studio build when reporting feedback.",
                body: """
                LocalOCR Studio \(version) (\(build))

                The app and OCR features require Apple silicon and macOS 14 or later. Local Intelligence requires macOS 26 or later and provider-specific availability. Include the exact LocalOCR version, build, Mac model, and macOS version/build in beta feedback.
                """,
                keywords: ["version", "build", "compatibility", "macOS"]
            ),
        ]
    }
}

import AppKit
import SwiftUI

@MainActor
public struct AgentConnectionGuideView: View {
    @Bindable private var model: AgentConnectionGuideModel

    public init(model: AgentConnectionGuideModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introduction
                helperPath
                connectionInstructions
                consentControls
                toolsAndTroubleshooting
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 620)
        .accessibilityIdentifier("studio.agent-guide")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to Your Agent")
                .font(.largeTitle.bold())
            Text(
                "LocalOCR uses a local stdio MCP server. Your MCP client starts the helper and exchanges tool messages with it on this Mac; LocalOCR does not open a network listener or edit your client configuration."
            )
        }
    }

    private var helperPath: some View {
        GuideSection(title: "Bundled helper path") {
            codeBlock(model.helperPath, copyIdentifier: "studio.agent-guide.copy-path")
        }
    }

    private var connectionInstructions: some View {
        GuideSection(title: "Client setup") {
            TabView {
                clientInstructions(
                    commands: model.codexCommands,
                    note: "Run these commands in Terminal, then use /mcp in Codex to inspect the connection.",
                    copyIdentifier: "studio.agent-guide.copy-codex"
                )
                .tabItem { Text("Codex CLI") }

                clientInstructions(
                    commands: model.claudeCodeCommands,
                    note: "Run these commands in Terminal, then use /mcp in Claude Code. The default scope is the current project.",
                    copyIdentifier: "studio.agent-guide.copy-claude"
                )
                .tabItem { Text("Claude Code") }

                clientInstructions(
                    commands: model.genericStdioJSON,
                    note: "Use your client's current documentation to add this stdio entry and verify it. LocalOCR does not edit the configuration for you.",
                    copyIdentifier: "studio.agent-guide.copy-json"
                )
                .tabItem { Text("Other stdio clients") }
            }
            .frame(height: 190)
        }
    }

    private var consentControls: some View {
        GuideSection(title: "External-data acknowledgment") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.disclosure)
                Toggle(
                    model.externalProviderRiskAcknowledgment,
                    isOn: $model.externalProviderRiskAccepted
                )
                .accessibilityIdentifier("studio.agent-guide.external-risk")
                Toggle(
                    model.documentToolAccessAcknowledgment,
                    isOn: $model.documentToolAccessAccepted
                )
                .accessibilityIdentifier("studio.agent-guide.document-access")

                HStack(spacing: 12) {
                    Text(receiptStatusText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("studio.agent-guide.receipt-status")
                    Spacer()
                    Button("Revoke") {
                        Task { try? await model.revoke() }
                    }
                    .disabled(model.receiptStatus != .current || model.isUpdatingConsent)
                    .accessibilityIdentifier("studio.agent-guide.revoke")
                    Button("Accept and Enable MCP Tools") {
                        Task { try? await model.accept() }
                    }
                    .disabled(!model.canAccept)
                    .accessibilityIdentifier("studio.agent-guide.accept")
                }

                if let consentError = model.consentError {
                    Text(consentError)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var toolsAndTroubleshooting: some View {
        GuideSection(title: "Tools and troubleshooting") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nine document tools")
                    .font(.headline)
                Text(
                    "get_pdf_page_count, inspect_pdf, ocr_pdf, ocr_pdf_batch, ocr_image, make_searchable_pdf, summarize_document, organize_document, extract_document_fields"
                )
                Text("Safe examples")
                    .font(.headline)
                Text("Try “Inspect this local PDF” or “OCR these test PDFs,” using absolute paths to non-sensitive files.")
                Text("If setup fails, confirm the helper path, client configuration, macOS file permissions, current acknowledgment status, and Local Intelligence availability. The MCP client—not LocalOCR—must have permission to read each selected file.")
            }
        }
    }

    private var receiptStatusText: String {
        switch model.receiptStatus {
        case .loading:
            "Acknowledgment status: Checking…"
        case .current:
            "Acknowledgment status: Current"
        case .required:
            "Acknowledgment status: Required"
        }
    }

    private func clientInstructions(
        commands: String,
        note: String,
        copyIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note)
            codeBlock(commands, copyIdentifier: copyIdentifier)
        }
        .padding(.top, 8)
    }

    private func codeBlock(_ value: String, copyIdentifier: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .accessibilityIdentifier(copyIdentifier)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GuideSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

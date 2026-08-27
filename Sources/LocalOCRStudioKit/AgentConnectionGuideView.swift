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
                    guidance: model.codexScopeGuidance,
                    removalCommand: model.codexRemovalCommand,
                    copyIdentifier: "studio.agent-guide.copy-codex",
                    removalCopyIdentifier: "studio.agent-guide.copy-codex-remove"
                )
                .tabItem { Text("Codex CLI") }

                clientInstructions(
                    commands: model.claudeCodeCommands,
                    guidance: model.claudeCodeScopeGuidance,
                    removalCommand: model.claudeCodeRemovalCommand,
                    copyIdentifier: "studio.agent-guide.copy-claude",
                    removalCopyIdentifier: "studio.agent-guide.copy-claude-remove"
                )
                .tabItem { Text("Claude Code") }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Use your client's current documentation to add, inspect, and remove this stdio entry. LocalOCR does not edit the configuration for you.")
                    codeBlock(
                        model.genericStdioJSON,
                        copyIdentifier: "studio.agent-guide.copy-json"
                    )
                }
                .padding(.top, 8)
                .tabItem { Text("Other stdio clients") }
            }
            .frame(height: 270)
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
                Text("OCR and PDF tools: \(model.ocrAndPDFTools.joined(separator: ", "))")
                Text("Local Intelligence tools: \(model.localIntelligenceTools.joined(separator: ", "))")
                Text(model.localIntelligenceRequirements)
                Text("Safe examples")
                    .font(.headline)
                ForEach(model.safeExamplePrompts, id: \.self) { prompt in
                    Text("• \(prompt)")
                }
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
        guidance: String,
        removalCommand: String,
        copyIdentifier: String,
        removalCopyIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guidance)
            codeBlock(commands, copyIdentifier: copyIdentifier)
            Text("Removal")
                .font(.headline)
            codeBlock(removalCommand, copyIdentifier: removalCopyIdentifier)
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

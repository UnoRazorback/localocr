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
                detectedClients
                consentControls
                connectionActions
                manualFallback
                toolsAndTroubleshooting
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.localOCRStudioGround)
        .frame(minWidth: 760, minHeight: 660)
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

    private var detectedClients: some View {
        GuideSection(title: "Detected clients") {
            VStack(alignment: .leading, spacing: 10) {
                switch model.discoveryState {
                case .idle, .discovering:
                    ProgressView("Checking this Mac…")
                case .unavailable:
                    Text("LocalOCR did not find a supported Codex or Claude Code installation in its bounded application and executable locations. Manual setup remains available below.")
                        .foregroundStyle(.secondary)
                case .available:
                    ForEach(model.detectedClients) { client in
                        clientButton(client)
                    }
                }

                Button("Check Again") {
                    Task { await model.refreshClients() }
                }
                .disabled(model.discoveryState == .discovering || model.isChangingConnection)
                .accessibilityIdentifier("studio.agent-guide.refresh-clients")
            }
        }
    }

    private var connectionActions: some View {
        GuideSection(title: "Connection") {
            VStack(alignment: .leading, spacing: 12) {
                if let client = model.selectedClient {
                    Text("Selected: \(client.displayName)")
                        .font(.headline)
                    Text(clientStateText(model.clientState(for: client)))
                        .foregroundStyle(clientStateColor(model.clientState(for: client)))
                        .accessibilityIdentifier("studio.agent-guide.client-status")

                    if client.kind == .claudeCode {
                        Picker("Claude connection scope", selection: $model.claudeScope) {
                            Text("Choose a scope").tag(ClaudeMCPConnectionScope?.none)
                            Text("This project (local)").tag(ClaudeMCPConnectionScope?.some(.local))
                            Text("All projects (user)").tag(ClaudeMCPConnectionScope?.some(.user))
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("studio.agent-guide.scope")
                    }

                    Toggle(
                        "I confirm this change for \(client.displayName) and the scope shown above.",
                        isOn: $model.connectionChangeConfirmed
                    )
                    .accessibilityIdentifier("studio.agent-guide.confirm-change")

                    HStack(spacing: 12) {
                        Button("Connect") {
                            Task { try? await model.connectSelectedClient() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.localOCRStudioOlive)
                        .disabled(!model.canConnect)
                        .accessibilityIdentifier("studio.agent-guide.connect")

                        Button("Disconnect") {
                            Task { try? await model.disconnectSelectedClient() }
                        }
                        .disabled(!model.canDisconnect)
                        .accessibilityIdentifier("studio.agent-guide.disconnect")
                    }
                    Text(model.restartGuidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a detected client to inspect or change its LocalOCR registration.")
                        .foregroundStyle(.secondary)
                }

                if let connectionError = model.connectionError {
                    Text(connectionError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("studio.agent-guide.connection-error")
                }
            }
        }
    }

    private var manualFallback: some View {
        GuideSection(title: "Manual fallback") {
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
                    Text("Other stdio clients are copy-only in this beta. Use the client's current documentation to add, inspect, and remove this entry; LocalOCR does not edit generic client configuration.")
                    codeBlock(
                        model.genericStdioJSON,
                        copyIdentifier: "studio.agent-guide.copy-json"
                    )
                }
                .padding(.top, 8)
                .tabItem { Text("Other stdio clients") }
            }
            .frame(height: 290)
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

    private func clientButton(_ client: AgentClientInstallation) -> some View {
        let selected = model.selectedClientID == client.id
        return Button {
            model.selectedClientID = client.id
            model.connectionChangeConfirmed = false
            if client.kind != .claudeCode {
                model.claudeScope = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: client.kind == .codex ? "terminal" : "chevron.left.forwardslash.chevron.right")
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(.headline)
                    Text(client.executableURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(clientStateText(model.clientState(for: client)))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(clientStateColor(model.clientState(for: client)))
            }
            .padding(12)
            .background(
                selected ? Color.localOCRStudioOlive.opacity(0.13) : Color.localOCRStudioSurface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.localOCRStudioOlive : Color.secondary.opacity(0.18))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio.agent-guide.client.\(client.kind.rawValue)")
    }

    private func clientStateText(_ state: AgentClientGuideState) -> String {
        switch state {
        case .unavailable: "Unavailable"
        case .inspecting: "Checking…"
        case .disconnected: "Not connected"
        case .connected: "Connected to this app"
        case .conflict: "Different LocalOCR registered"
        case .failed: "Check failed"
        }
    }

    private func clientStateColor(_ state: AgentClientGuideState) -> Color {
        switch state {
        case .connected: Color.localOCRStudioOlive
        case .conflict, .failed: .red
        case .unavailable, .inspecting, .disconnected: .secondary
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

import CryptoKit
import Foundation
import LocalOCRModelCore
import SwiftUI

struct StudioProcessingRouteDisclosure: View {
    let route: StudioProcessingRoute
    let accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(Color.localOCRStudioOlive)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(route.path)
                    .font(.caption.weight(.semibold))
                Text(route.modelDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(route.location)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.localOCRStudioOlive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.localOCRStudioOlive.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.accessibilityText)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct StudioLocalModelManagerView: View {
    @Bindable var model: StudioLocalModelManagerViewModel
    @Environment(\.dismiss) private var dismiss

    private let contract = StudioLocalModelManagerContract()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activeSelection

                    Text(contract.discoveryExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("studio.models.discovery-explanation")

                    ForEach(providerOrder, id: \.self) { provider in
                        providerSection(provider)
                    }
                }
                .padding(22)
            }

            Divider()

            footer
                .padding(18)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 680)
        .background(Color.localOCRStudioGround)
        .tint(.localOCRStudioOlive)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.models.sheet")
        .task { await model.detect() }
        .sheet(isPresented: confirmationIsPresented) {
            confirmationSheet
        }
        .alert(
            model.error?.title ?? "Local Model Action Failed",
            isPresented: errorIsPresented
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            if let error = model.error { Text(error.message) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(contract.title)
                    .font(.system(.title2, design: .default, weight: .semibold))
                Text(contract.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let route = StudioProcessingRoute(selection: model.selection) {
                Text(route.location)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.localOCRStudioOlive)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.localOCRStudioOlive.opacity(0.11), in: Capsule())
                    .accessibilityLabel("Active route: \(route.location)")
                    .accessibilityIdentifier("studio.models.active-badge")
            }
        }
    }

    @ViewBuilder
    private var activeSelection: some View {
        if let route = StudioProcessingRoute(selection: model.selection) {
            StudioProcessingRouteDisclosure(
                route: route,
                accessibilityIdentifier: "studio.models.active-route"
            )
        } else {
            Label(selectionMessage, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("studio.models.selection-message")
        }
    }

    private func providerSection(_ provider: LocalModelProviderID) -> some View {
        let rows = model.models.filter { $0.identity.provider == provider }
        return VStack(alignment: .leading, spacing: 0) {
            Text(providerTitle(provider))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.bottom, 8)

            Divider()

            if rows.isEmpty {
                Text(emptyMessage(provider))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows) { row in
                    modelRow(row)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.models.provider.\(provider.rawValue)")
    }

    private func modelRow(_ row: StudioLocalModelRow) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.modelName)
                    .font(row.identity.provider == .appleFoundationModels ? .callout : .system(.callout, design: .monospaced))
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(row.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(row))
                        .accessibilityIdentifier("studio.models.status.\(row.accessibilityKey)")

                    if let qualifiedAt = row.qualifiedAt {
                        Text("· Tested \(qualifiedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if row.locality != .verifiedLocal || !row.available {
                    Text(row.localityReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if row.identity.provider != .appleFoundationModels {
                Button(row.qualification == .untested ? "Test" : "Recheck") {
                    Task { await model.test(row.identity) }
                }
                .disabled(!row.canTest || model.qualifyingIdentity != nil)
                .accessibilityIdentifier("studio.models.test.\(row.accessibilityKey)")
            }

            if row.selected {
                Text("Selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.localOCRStudioOlive)
                    .accessibilityIdentifier("studio.models.selected.\(row.accessibilityKey)")
            } else {
                Button("Select") {
                    if row.identity.provider == .appleFoundationModels {
                        Task { await model.selectApple() }
                    } else {
                        model.prepareExternalSelection(row.identity)
                    }
                }
                .disabled(!row.canSelect || model.selectingIdentity != nil)
                .accessibilityIdentifier("studio.models.select.\(row.accessibilityKey)")
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.models.row.\(row.accessibilityKey)")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.detect() }
            } label: {
                if model.isDetecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Detect")
                }
            }
            .disabled(model.isDetecting)
            .accessibilityLabel(model.isDetecting ? "Detecting local models" : "Detect")
            .accessibilityIdentifier("studio.models.detect")

            Button("Reset selection", role: .destructive) {
                Task { await model.reset() }
            }
            .accessibilityIdentifier("studio.models.reset")

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("studio.models.done")
        }
    }

    @ViewBuilder
    private var confirmationSheet: some View {
        if let confirmation = model.externalConfirmation {
            VStack(alignment: .leading, spacing: 18) {
                Label("Confirm Local Model Route", systemImage: "lock.shield")
                    .font(.system(.headline, design: .rounded, weight: .semibold))

                VStack(alignment: .leading, spacing: 5) {
                    Text(confirmation.providerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(confirmation.modelName)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .textSelection(.enabled)
                }

                Text(confirmation.statement)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel", role: .cancel) { model.cancelExternalSelection() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") {
                        Task { await model.confirmExternalSelection() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectingIdentity != nil)
                }
            }
            .padding(24)
            .frame(width: 500)
            .background(Color.localOCRStudioGround)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.models.confirmation")
        }
    }

    private var selectionMessage: String {
        switch model.selection {
        case .none: "No local model selection has been loaded yet."
        case .reset: "No local model is selected. Choose one for future Local Intelligence actions."
        case .invalid: "The saved selection is no longer valid. Choose a current local model."
        case .selected: ""
        }
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { model.externalConfirmation != nil },
            set: { if !$0 { model.cancelExternalSelection() } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.error != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    private let providerOrder: [LocalModelProviderID] = [
        .appleFoundationModels, .ollama, .lmStudio,
    ]

    private func providerTitle(_ provider: LocalModelProviderID) -> String {
        switch provider {
        case .appleFoundationModels: "APPLE"
        case .ollama: "OLLAMA"
        case .lmStudio: "LM STUDIO"
        }
    }

    private func emptyMessage(_ provider: LocalModelProviderID) -> String {
        switch provider {
        case .appleFoundationModels: "The Apple system model is not available on this Mac."
        case .ollama: "No Ollama models were detected. Start your existing local harness, then choose Detect."
        case .lmStudio: "No LM Studio models were detected. Start your existing local harness, then choose Detect."
        }
    }

    private func statusColor(_ row: StudioLocalModelRow) -> Color {
        row.canSelect || row.selected ? .localOCRStudioOlive : .secondary
    }
}

extension StudioLocalModelRow {
    var accessibilityKey: String {
        StudioModelAccessibilityKey.key(for: identity)
    }
}

enum StudioModelAccessibilityKey {
    static func key(for identity: LocalModelIdentity) -> String {
        let exact = [
            identity.provider.rawValue,
            identity.model,
            identity.fingerprint ?? "",
            identity.harnessVersion ?? "",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(exact.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

import LocalOCRIntelligence
import LocalOCRModelCore
import SwiftUI

struct StudioLocalIntelligenceContract {
    let availability: IntelligenceAvailability

    let title = "Local Intelligence"
    let manageModelsLabel = "Manage Local Models"
    let modelExplanation = "Apple selects the installed system model. macOS does not expose its specific model name or version."
    let summaryActionLabel = "Summarize document with Local Intelligence"
    let organizationActionLabel = "Suggest document name and tags with Local Intelligence"
    let fieldsActionLabel = "Extract date, total, and reference number with Local Intelligence"

    var unavailableGuidance: String? {
        switch availability {
        case .available:
            nil
        case .requiresMacOS26:
            "Local Intelligence requires macOS 26 or later."
        case .deviceNotEligible:
            "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings to use Local Intelligence."
        case .modelNotReady:
            "Apple Intelligence is downloading or not ready yet. Try again when setup is complete."
        case .unsupportedLanguage:
            "The current Apple Intelligence language is not supported."
        }
    }
}

struct StudioLocalIntelligenceView: View {
    @Bindable var model: StudioIntelligenceViewModel
    @Bindable var managerModel: StudioLocalModelManagerViewModel
    @State private var isManagingModels = false

    private var contract: StudioLocalIntelligenceContract {
        StudioLocalIntelligenceContract(availability: model.availability)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(contract.title, systemImage: "apple.intelligence")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
                Button(contract.manageModelsLabel) { isManagingModels = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("studio.intelligence.manage-models")
            }

            if let route = StudioProcessingRoute(selection: managerModel.selection) {
                StudioProcessingRouteDisclosure(
                    route: route,
                    accessibilityIdentifier: "studio.intelligence.active-route"
                )
                if route.location == "On device" {
                    Text(contract.modelExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No local model is selected for future Local Intelligence actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let recovery = model.recovery {
                recoveryView(recovery)
            }

            if let guidance = contract.unavailableGuidance {
                Label(guidance, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            intelligenceAction(
                title: "Summarize",
                label: contract.summaryActionLabel,
                identifier: "studio.intelligence.summarize",
                progressIdentifier: "studio.intelligence.summary-progress",
                state: model.summaryState,
                action: model.summarize,
                result: summaryResult
            )

            Divider()

            intelligenceAction(
                title: "Suggest Name & Tags",
                label: contract.organizationActionLabel,
                identifier: "studio.intelligence.organize",
                progressIdentifier: "studio.intelligence.organization-progress",
                state: model.organizationState,
                action: model.organize,
                result: organizationResult
            )

            Divider()

            intelligenceAction(
                title: "Extract Fields",
                label: contract.fieldsActionLabel,
                identifier: "studio.intelligence.fields",
                progressIdentifier: "studio.intelligence.fields-progress",
                state: model.fieldsState,
                action: model.extractFields,
                result: fieldsResult
            )
        }
        .padding(18)
        .background(Color.localOCRStudioOlive.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.localOCRStudioOlive.opacity(0.22))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.local-intelligence")
        .task { await managerModel.refreshSelection() }
        .sheet(isPresented: $isManagingModels) {
            StudioLocalModelManagerView(model: managerModel)
        }
    }

    @ViewBuilder
    private func intelligenceAction<Value: Sendable & Equatable, ResultContent: View>(
        title: String,
        label: String,
        identifier: String,
        progressIdentifier: String,
        state: StudioIntelligenceState<Value>,
        action: @escaping () -> Void,
        @ViewBuilder result: (Value) -> ResultContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Button(title, action: action)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(identifier)
                    .disabled(isRunning(state) || model.availability != .available)

                if isRunning(state) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("\(title) in progress")
                        .accessibilityIdentifier(progressIdentifier)
                }
            }

            switch state {
            case .idle, .running, .unavailable:
                EmptyView()
            case let .result(value):
                VStack(alignment: .leading, spacing: 8) {
                    result(value)
                    if let provenance = provenance(for: state) {
                        StudioProcessingRouteDisclosure(
                            route: StudioProcessingRoute(provenance: provenance),
                            accessibilityIdentifier: resultRouteIdentifier(for: state)
                        )
                    }
                }
            case let .failure(error):
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func provenance<Value>(for state: StudioIntelligenceState<Value>) -> LocalModelProvenance? {
        if Value.self == IntelligenceSummary.self { return model.summaryModel }
        if Value.self == OrganizationSuggestion.self { return model.organizationModel }
        return model.fieldsModel
    }

    private func resultRouteIdentifier<Value>(for state: StudioIntelligenceState<Value>) -> String {
        if Value.self == IntelligenceSummary.self { return "studio.intelligence.summary-route" }
        if Value.self == OrganizationSuggestion.self { return "studio.intelligence.organization-route" }
        return "studio.intelligence.fields-route"
    }

    private func recoveryView(_ recovery: StudioIntelligenceRecovery) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(recovery.message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Retry", action: model.retryRecovery)
                    .accessibilityIdentifier("studio.intelligence.recovery.retry")
                Button("Choose Another Local Model") { isManagingModels = true }
                    .accessibilityIdentifier("studio.intelligence.recovery.choose")
                if managerModel.models.contains(where: {
                    $0.identity.provider == .appleFoundationModels && $0.available
                }) {
                    Button("Use Apple System Model") {
                        Task {
                            await managerModel.selectApple()
                            await model.refreshAvailability()
                        }
                    }
                    .accessibilityIdentifier("studio.intelligence.recovery.apple")
                }
            }
        }
        .padding(12)
        .background(Color.localOCRStudioOlive.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.intelligence.recovery")
    }

    private func isRunning<Value>(_ state: StudioIntelligenceState<Value>) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func summaryResult(_ summary: IntelligenceSummary) -> some View {
        Text(summary.text + citationSuffix(summary.citations))
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func organizationResult(_ suggestion: OrganizationSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested name: \(suggestion.title)")
            Text("Category: \(suggestion.category)")
            Text("Tags: \(suggestion.tags.isEmpty ? "None" : suggestion.tags.joined(separator: ", "))")
            if !suggestion.citations.isEmpty {
                Text(citationLabel(suggestion.citations))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func fieldsResult(_ fields: [ExtractedDocumentField]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fields, id: \.name) { field in
                Text(fieldLabel(field))
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func fieldLabel(_ field: ExtractedDocumentField) -> String {
        let displayName: String
        switch field.name {
        case "date": displayName = "Date"
        case "total": displayName = "Total"
        case "reference_number": displayName = "Reference number"
        default: displayName = field.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let value = field.value ?? "Not found"
        let citation = field.sourcePage.map { " [Page \($0)]" } ?? ""
        return "\(displayName): \(value)\(citation)"
    }

    private func citationSuffix(_ citations: [IntelligenceCitation]) -> String {
        citations.isEmpty ? "" : " \(citationLabel(citations))"
    }

    private func citationLabel(_ citations: [IntelligenceCitation]) -> String {
        let pages = Array(Set(citations.map(\.page))).sorted()
        if pages.count == 1, let page = pages.first {
            return "[Page \(page)]"
        }
        return "[Pages \(pages.map(String.init).joined(separator: ", "))]"
    }
}

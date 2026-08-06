import SwiftUI

struct StudioResultActionAvailability {
    let footerActionsAreEnabled: Bool

    init(isCreatingSearchablePDF: Bool) {
        footerActionsAreEnabled = !isCreatingSearchablePDF
    }
}

struct StudioResultView: View {
    let result: StudioDocumentResult
    let isCreatingSearchablePDF: Bool
    let searchableProgress: StudioProgress?
    let onProcessAnother: () -> Void
    let onCopy: () -> Void
    let onSaveText: () -> Void
    let onCreateSearchablePDF: () -> Void

    private var contract: StudioViewContract {
        StudioViewContract(state: .result(result))
    }

    private var actionAvailability: StudioResultActionAvailability {
        StudioResultActionAvailability(
            isCreatingSearchablePDF: isCreatingSearchablePDF
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: result.kind == .pdf ? "doc.richtext" : "photo")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(contract.primaryTitle)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .lineLimit(1)

                    Text(contract.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(result.text.isEmpty ? "No text was recognized in this document." : result.text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(26)
                    .accessibilityIdentifier("studio.result-text")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75))
            }
            .shadow(color: .black.opacity(0.045), radius: 12, y: 4)

            HStack(spacing: 10) {
                if isCreatingSearchablePDF {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("studio.progress")

                    Text(searchableProgress?.statusText ?? "Preparing searchable PDF")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if contract.canProcessAnotherDocument {
                    Button("Process Another Document", action: onProcessAnother)
                        .accessibilityIdentifier("studio.process-another")
                }

                Spacer()

                Button("Copy", action: onCopy)
                    .accessibilityIdentifier("studio.copy")

                Button("Save Text", action: onSaveText)
                    .accessibilityIdentifier("studio.save-text")

                if contract.canCreateSearchablePDF {
                    Button("Create Searchable PDF", action: onCreateSearchablePDF)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("studio.create-searchable")
                }
            }
            .disabled(!actionAvailability.footerActionsAreEnabled)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}

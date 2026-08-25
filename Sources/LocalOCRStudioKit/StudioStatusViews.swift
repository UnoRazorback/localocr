import SwiftUI

public struct StudioViewContract: Equatable {
    public let primaryTitle: String
    public let statusText: String
    public let canCopy: Bool
    public let canSaveText: Bool
    public let canCreateSearchablePDF: Bool
    public let canProcessAnotherDocument: Bool
    public let canCancel: Bool
    public let canRetry: Bool

    public init(state: StudioState) {
        switch state {
        case .empty:
            primaryTitle = "Drop a document here"
            statusText = "PDF or image • Processed locally on this Mac."
            canCopy = false
            canSaveText = false
            canCreateSearchablePDF = false
            canProcessAnotherDocument = false
            canCancel = false
            canRetry = false

        case let .processing(sourceURL, progress):
            primaryTitle = sourceURL.lastPathComponent
            statusText = "\(progress.statusText) • Processing locally on this Mac."
            canCopy = false
            canSaveText = false
            canCreateSearchablePDF = false
            canProcessAnotherDocument = false
            canCancel = true
            canRetry = false

        case let .result(result):
            primaryTitle = result.sourceURL.lastPathComponent
            statusText = result.summaryText
            canCopy = true
            canSaveText = true
            canCreateSearchablePDF = result.kind == .pdf
            canProcessAnotherDocument = true
            canCancel = false
            canRetry = false

        case let .failure(_, error):
            primaryTitle = error.title
            statusText = error.message
            canCopy = false
            canSaveText = false
            canCreateSearchablePDF = false
            canProcessAnotherDocument = false
            canCancel = false
            canRetry = true
        }
    }
}

struct StudioProcessingView: View {
    let sourceURL: URL
    let progress: StudioProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 88, height: 88)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 7) {
                Text(sourceURL.lastPathComponent)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(progress.statusText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            progressView
                .frame(maxWidth: 360)
                .accessibilityIdentifier("studio.progress")

            StudioOnDeviceBadge()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("studio.cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var progressView: some View {
        if case let .recognizing(page, total) = progress, total > 0 {
            ProgressView(value: Double(page), total: Double(total))
                .accessibilityLabel(progress.statusText)
        } else {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(progress.statusText)
        }
    }
}

struct StudioErrorView: View {
    let error: StudioPresentedError
    let onRetry: () -> Void
    let onChooseAnother: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .frame(width: 88, height: 88)

                Image(systemName: "doc.badge.exclamationmark")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text(error.title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(error.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let details = error.details {
                DisclosureGroup("Details") {
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .accessibilityIdentifier("studio.error-details")
                .frame(maxWidth: 440)
            }

            HStack(spacing: 10) {
                Button("Choose Another Document", action: onChooseAnother)
                    .accessibilityIdentifier("studio.choose-another")

                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("studio.retry")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension StudioProgress {
    var statusText: String {
        switch self {
        case .inspecting:
            "Inspecting document"
        case let .recognizing(page, total):
            "Recognizing page \(page) of \(total)"
        case .assembling:
            "Preparing results"
        }
    }
}

private extension StudioDocumentResult {
    var summaryText: String {
        guard kind == .pdf else {
            return "Image • Text ready"
        }

        let pages = "\(pageCount) \(pageCount == 1 ? "page" : "pages")"
        let searchable = "\(searchablePages) already searchable"
        let recognizedPages = max(0, ocrNeededPages - failedPages.count)
        let recognized = "\(recognizedPages) recognized"
        let failures = failedPages.isEmpty
            ? nil
            : "\(failedPages.count) \(failedPages.count == 1 ? "page needs" : "pages need") review"

        return [pages, searchable, recognized, failures]
            .compactMap { $0 }
            .joined(separator: " • ")
    }
}

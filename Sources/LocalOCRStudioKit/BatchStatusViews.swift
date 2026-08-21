import Foundation
import SwiftUI

struct BatchDropAccumulator {
    private var activeGeneration: UUID?
    private var expectedCount = 0
    private var resolvedIndices: Set<Int> = []
    private var resolvedURLs: [Int: URL] = [:]

    mutating func begin(expectedCount: Int) -> UUID {
        let generation = UUID()
        activeGeneration = generation
        self.expectedCount = max(0, expectedCount)
        resolvedIndices = []
        resolvedURLs = [:]
        return generation
    }

    mutating func resolve(
        _ url: URL?,
        at index: Int,
        generation: UUID
    ) -> [URL]? {
        guard activeGeneration == generation,
              expectedCount > 0,
              (0..<expectedCount).contains(index),
              resolvedIndices.insert(index).inserted
        else {
            return nil
        }

        if let url, url.isFileURL {
            resolvedURLs[index] = url
        }
        guard resolvedIndices.count == expectedCount else { return nil }

        activeGeneration = nil
        return (0..<expectedCount).compactMap { resolvedURLs[$0] }
    }

    mutating func invalidate() {
        activeGeneration = nil
        expectedCount = 0
        resolvedIndices = []
        resolvedURLs = [:]
    }
}

enum BatchDiagnostics {
    static func make(
        version: String,
        build: String,
        phase: StudioBatchPhase,
        discovery: StudioBatchDiscovery?,
        items: [StudioBatchItem]
    ) -> String {
        let summary = StudioBatchSummary(
            items: items,
            skippedCount: discovery?.skipped.count ?? 0
        )
        let acceptedCount = discovery?.candidates.count ?? items.count
        let duplicateCount = discovery?.duplicateCount ?? 0
        var lines = [
            "LocalOCR Studio \(version) (\(build))",
            "Phase: \(phase.diagnosticsName)",
            "Supported: \(acceptedCount)",
            "Completed: \(summary.completed)",
            "Failed: \(summary.failed)",
            "Skipped: \(summary.skipped)",
            "Cancelled: \(summary.cancelled)",
            "Duplicates: \(duplicateCount)",
        ]

        for item in items {
            lines.append("")
            lines.append("Source: \(item.candidate.sourceURL.path)")
            lines.append(contentsOf: item.state.diagnosticsLines)
        }
        for skipped in discovery?.skipped ?? [] {
            lines.append("")
            lines.append("Source: \(skipped.sourceURL.path)")
            lines.append("State: skipped")
            lines.append("Category: \(skipped.reason.title)")
            lines.append("Message: \(skipped.reason.message)")
        }

        return lines.joined(separator: "\n")
    }
}

private extension StudioBatchPhase {
    var diagnosticsName: String {
        switch self {
        case .empty: "empty"
        case .reviewing: "reviewing"
        case .processing: "processing"
        case .complete: "complete"
        }
    }
}

private extension StudioBatchItemState {
    var diagnosticsLines: [String] {
        switch self {
        case .queued:
            ["State: queued"]
        case .processing:
            ["State: processing"]
        case .completed:
            ["State: completed"]
        case let .skipped(issue):
            [
                "State: skipped",
                "Category: \(issue.title)",
                "Message: \(issue.message)",
            ]
        case let .failed(issue):
            [
                "State: failed",
                "Category: \(issue.title)",
                "Message: \(issue.message)",
            ]
        case .cancelled:
            ["State: cancelled"]
        }
    }
}

public struct BatchViewContract: Equatable, Sendable {
    public let primaryTitle: String
    public let summaryText: String
    public let canAddInputs: Bool
    public let canChooseOutput: Bool
    public let canStart: Bool
    public let canCancel: Bool
    public let canRetryFailed: Bool
    public let canRevealOutput: Bool
    public let canCopyDiagnostics: Bool
    public let canStartNewBatch: Bool
    public let canReturnToSingle: Bool

    public init(
        phase: StudioBatchPhase,
        acceptedCount: Int,
        skippedCount: Int,
        duplicateCount: Int = 0,
        completedCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        isPreparedToStart: Bool,
        hasOutputRoot: Bool
    ) {
        let hasAcceptedInputs = acceptedCount > 0
        let hasInspectableItems = acceptedCount + skippedCount > 0
        let presentedPhase: StudioBatchPhase = phase == .empty && skippedCount > 0
            ? .reviewing
            : phase

        switch presentedPhase {
        case .empty:
            primaryTitle = "Prepare Batch"
            summaryText = "Add files or folders to begin"
        case .reviewing:
            primaryTitle = "Review Batch"
            summaryText = Self.reviewSummary(
                acceptedCount: acceptedCount,
                skippedCount: skippedCount,
                duplicateCount: duplicateCount
            )
        case .processing:
            primaryTitle = "Processing Batch"
            summaryText = "\(completedCount) of \(acceptedCount) completed • \(skippedCount) skipped"
        case .complete:
            primaryTitle = "Batch Complete"
            summaryText = [
                "\(completedCount) completed",
                "\(failedCount) failed",
                "\(skippedCount) skipped",
                "\(cancelledCount) cancelled",
            ].joined(separator: " • ")
        }

        canAddInputs = phase == .empty || phase == .reviewing
        canChooseOutput = canAddInputs
        canStart = phase == .reviewing
            && hasAcceptedInputs
            && hasOutputRoot
            && isPreparedToStart
        canCancel = phase == .processing
        canRetryFailed = phase == .complete && failedCount > 0 && hasOutputRoot
        canRevealOutput = phase == .complete && hasOutputRoot
        canCopyDiagnostics = hasInspectableItems
        canStartNewBatch = phase == .complete
        canReturnToSingle = phase != .processing
    }

    private static func reviewSummary(
        acceptedCount: Int,
        skippedCount: Int,
        duplicateCount: Int
    ) -> String {
        var parts = [
            "\(acceptedCount) supported",
            "\(skippedCount) skipped",
        ]
        if duplicateCount > 0 {
            let noun = duplicateCount == 1 ? "duplicate" : "duplicates"
            parts.append("\(duplicateCount) \(noun)")
        }
        return parts.joined(separator: " • ")
    }
}

struct BatchRowContract: Equatable, Identifiable {
    let id: UUID
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    init(index: Int, item: StudioBatchItem) {
        id = item.id
        accessibilityIdentifier = "studio.batch.row.\(item.id.uuidString.lowercased())"

        var labelParts = [
            "Item \(index + 1)",
            item.candidate.sourceURL.lastPathComponent,
            item.candidate.kind.label,
            item.state.label,
        ]
        switch item.state {
        case let .processing(progress):
            labelParts.append(progress.statusText)
        case let .failed(issue), let .skipped(issue):
            labelParts.append(issue.message)
        case let .completed(outputURL):
            labelParts.append("Output \(outputURL.path)")
        case .queued, .cancelled:
            break
        }
        accessibilityLabel = labelParts.joined(separator: ", ")
    }
}

@MainActor
struct BatchQueueRowView: View {
    @Bindable private var coordinator: StudioBatchCoordinator
    let index: Int
    let itemID: UUID

    init(
        index: Int,
        itemID: UUID,
        coordinator: StudioBatchCoordinator
    ) {
        self.index = index
        self.itemID = itemID
        self._coordinator = Bindable(coordinator)
    }

    var body: some View {
        Group {
            if let item = coordinator.items.first(where: { $0.id == itemID }) {
                BatchQueueRowContent(index: index, item: item)
            }
        }
    }
}

private struct BatchQueueRowContent: View {
    let index: Int
    let item: StudioBatchItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BatchStatusRail(index: index, state: item.state)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.candidate.sourceURL.lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Label(item.state.label, systemImage: item.state.symbolName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(item.state.foregroundStyle)
                        .accessibilityLabel("Status: \(item.state.label)")
                }

                Text(item.candidate.relativePath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(item.candidate.kind.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if case let .processing(progress) = item.state {
                    Text(progress.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Progress: \(progress.statusText)")
                }

                itemDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(contract.accessibilityLabel)
        .accessibilityIdentifier(contract.accessibilityIdentifier)
    }

    private var contract: BatchRowContract {
        BatchRowContract(index: index, item: item)
    }

    @ViewBuilder
    private var itemDetails: some View {
        switch item.state {
        case let .completed(outputURL):
            Text("Output: \(outputURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(issue), let .skipped(issue):
            DisclosureGroup("Details") {
                BatchIssueDetails(issue: issue)
                    .padding(.top, 4)
            }
            .font(.callout)
        case .queued, .processing, .cancelled:
            EmptyView()
        }
    }
}

struct BatchCandidateRowView: View {
    let index: Int
    let candidate: StudioBatchCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BatchStatusRail(index: index, state: .queued)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(candidate.sourceURL.lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Label("Queued", systemImage: "clock")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Status: Queued")
                }

                Text(candidate.relativePath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(candidate.kind.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Item \(index + 1), \(candidate.sourceURL.lastPathComponent), \(candidate.kind.label), Queued"
        )
        .accessibilityIdentifier("studio.batch.row.\(candidate.id.uuidString.lowercased())")
    }
}

struct BatchSkippedRowView: View {
    let index: Int
    let skipped: StudioBatchSkippedInput

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BatchStatusRail(index: index, state: .skipped(skipped.reason))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(skipped.sourceURL.lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Label("Skipped", systemImage: "forward.end")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Status: Skipped")
                }

                Text(skipped.sourceURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                DisclosureGroup("Why this item was skipped") {
                    BatchIssueDetails(issue: skipped.reason)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Item \(index + 1), \(skipped.sourceURL.lastPathComponent), Skipped, \(skipped.reason.message)"
        )
        .accessibilityIdentifier("studio.batch.row.\(skipped.id.uuidString.lowercased())")
    }
}

private struct BatchStatusRail: View {
    let index: Int
    let state: StudioBatchItemState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                if case .queued = state {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: state.railSymbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.foregroundStyle)
                }
            }
            .frame(width: 26, height: 26)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 2, height: 34)
                .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }
}

private struct BatchIssueDetails: View {
    let issue: StudioBatchIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.title)
                .fontWeight(.medium)
            Text(issue.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension StudioDocumentKind {
    var label: String {
        switch self {
        case .pdf: "PDF"
        case .image: "Image"
        }
    }
}

private extension StudioBatchItemState {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .processing: "Processing"
        case .completed: "Completed"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .processing: "doc.text.magnifyingglass"
        case .completed: "checkmark.circle.fill"
        case .skipped: "forward.end"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var railSymbolName: String {
        switch self {
        case .queued: "circle"
        case .processing: "ellipsis"
        case .completed: "checkmark"
        case .skipped: "forward.fill"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .processing:
            .accentColor
        case .failed:
            Color(nsColor: .systemRed)
        case .completed:
            Color(nsColor: .systemGreen)
        case .queued, .skipped, .cancelled:
            .secondary
        }
    }
}

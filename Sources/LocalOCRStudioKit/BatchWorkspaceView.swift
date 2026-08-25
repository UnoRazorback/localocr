import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct BatchWorkspaceView: View {
    @Bindable private var coordinator: StudioBatchCoordinator
    private let onReturnToSingle: () -> Void

    @State private var isDropTargeted = false
    @State private var dropAccumulator = BatchDropAccumulator()
    @State private var pendingDropLoads: [Progress] = []

    public init(
        coordinator: StudioBatchCoordinator,
        onReturnToSingle: @escaping () -> Void
    ) {
        self._coordinator = Bindable(coordinator)
        self.onReturnToSingle = onReturnToSingle
    }

    public var body: some View {
        VStack(spacing: 14) {
            titleBar
            preparationBar
            if let actionError = coordinator.actionError {
                actionErrorBanner(actionError)
            }
            queue
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTargeted,
            perform: acceptDrop
        )
        .overlay {
            if isDropTargeted && contract.canAddInputs {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.localOCRStudioOlive, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear(perform: invalidatePendingDrop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Batch workspace")
        .accessibilityIdentifier("studio.batch.workspace")
    }

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(contract.primaryTitle)
                    .font(.title2.weight(.semibold))

                Text(contract.summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Batch summary: \(contract.summaryText)")
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                StudioOnDeviceBadge()
                Label("Sequential processing", systemImage: "arrow.down.to.line.compact")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Documents are processed one at a time")
            }
        }
    }

    private var preparationBar: some View {
        HStack(spacing: 10) {
            Button(action: showFilesPanel) {
                Label("Add Files", systemImage: "doc.badge.plus")
            }
            .disabled(!contract.canAddInputs)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint("Choose one or more PDF or image files.")
            .accessibilityIdentifier("studio.batch.add-files")

            Button(action: showFoldersPanel) {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!contract.canAddInputs)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .accessibilityHint("Choose one or more folders to scan recursively.")
            .accessibilityIdentifier("studio.batch.add-folder")

            Divider()
                .frame(height: 20)

            Button(action: showOutputPanel) {
                Label("Choose Output Folder", systemImage: "folder.badge.gearshape")
            }
            .disabled(!contract.canChooseOutput)
            .accessibilityIdentifier("studio.batch.choose-output")

            if let outputRoot = coordinator.outputRoot {
                Text(outputRoot.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(outputRoot.path)
                    .accessibilityLabel("Output folder: \(outputRoot.path)")
            } else {
                Text("Output folder required")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func actionErrorBanner(_ issue: StudioBatchIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.callout.weight(.semibold))
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.title). \(issue.message)")
        .accessibilityIdentifier("studio.batch.action-error")
    }

    private var queue: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if visibleAcceptedCount == 0 && skippedInputs.isEmpty {
                    emptyQueue
                } else {
                    if coordinator.items.isEmpty {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            BatchCandidateRowView(index: index, candidate: candidate)
                            Divider().padding(.leading, 56)
                        }
                    } else {
                        ForEach(
                            Array(coordinator.items.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            BatchQueueRowView(
                                index: index,
                                itemID: item.id,
                                coordinator: coordinator
                            )
                            Divider().padding(.leading, 56)
                        }
                    }

                    ForEach(Array(skippedInputs.enumerated()), id: \.element.id) { offset, skipped in
                        BatchSkippedRowView(
                            index: visibleAcceptedCount + offset,
                            skipped: skipped
                        )
                        if offset < skippedInputs.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.localOCRStudioSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityLabel("Batch queue")
    }

    private var emptyQueue: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)

            Text("Add files or folders to build the queue")
                .font(.body.weight(.medium))

            Text("PDFs and images are reviewed before anything is processed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .padding(30)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Button("Single Document", action: returnToSingle)
                .disabled(!contract.canReturnToSingle)
                .accessibilityHint(
                    contract.canReturnToSingle
                        ? "Return to the single-document start screen."
                        : "Cancel the batch before returning to single-document mode."
                )
                .accessibilityIdentifier("studio.batch.return-single")

            if contract.canCopyDiagnostics {
                Button("Copy Diagnostics", action: copyDiagnostics)
                    .accessibilityHint("Copies local batch state without recognized text.")
                    .accessibilityIdentifier("studio.batch.copy-diagnostics")
            }

            Spacer()

            switch coordinator.phase {
            case .empty, .reviewing:
                Button("Start Batch", action: coordinator.start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!contract.canStart)
                    .accessibilityHint(startHint)
                    .accessibilityIdentifier("studio.batch.start")

            case .processing:
                Button("Cancel Batch", action: coordinator.cancel)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("studio.batch.cancel")

            case .complete:
                Button("Reveal Output Folder", action: revealOutput)
                    .disabled(!contract.canRevealOutput)
                    .accessibilityIdentifier("studio.batch.reveal-output")

                Button("Retry Failed", action: coordinator.retryFailed)
                    .disabled(!contract.canRetryFailed)
                    .accessibilityIdentifier("studio.batch.retry-failed")

                Button("Start New Batch", action: coordinator.startNewBatch)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("studio.batch.new")
            }
        }
    }

    private var contract: BatchViewContract {
        BatchViewContract(
            phase: coordinator.phase,
            acceptedCount: candidates.count,
            skippedCount: coordinator.summary.skipped,
            duplicateCount: coordinator.discovery?.duplicateCount ?? 0,
            completedCount: coordinator.summary.completed,
            failedCount: coordinator.summary.failed,
            cancelledCount: coordinator.summary.cancelled,
            isPreparedToStart: coordinator.canStart,
            hasOutputRoot: coordinator.outputRoot != nil
        )
    }

    private var candidates: [StudioBatchCandidate] {
        coordinator.discovery?.candidates ?? coordinator.items.map(\.candidate)
    }

    private var skippedInputs: [StudioBatchSkippedInput] {
        coordinator.discovery?.skipped ?? []
    }

    private var visibleAcceptedCount: Int {
        coordinator.items.isEmpty ? candidates.count : coordinator.items.count
    }

    private var startHint: String {
        if candidates.isEmpty {
            return "Add at least one supported file or folder first."
        }
        if coordinator.outputRoot == nil {
            return "Choose an output folder first."
        }
        return "Process the reviewed queue one document at a time."
    }

    private func showFilesPanel() {
        guard contract.canAddInputs else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]

        guard panel.runModal() == .OK else { return }
        coordinator.addSelections(panel.urls)
    }

    private func showFoldersPanel() {
        guard contract.canAddInputs else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true

        guard panel.runModal() == .OK else { return }
        coordinator.addSelections(panel.urls)
    }

    private func showOutputPanel() {
        guard contract.canChooseOutput else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputRoot = panel.url else { return }
        coordinator.chooseOutputRoot(outputRoot)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard contract.canAddInputs else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        invalidatePendingDrop()
        let generation = dropAccumulator.begin(expectedCount: fileProviders.count)
        pendingDropLoads = fileProviders.enumerated().map { index, provider in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, _ in
                let resolvedURL = data.flatMap {
                    URL(dataRepresentation: $0, relativeTo: nil)
                }
                Task { @MainActor in
                    guard let selection = dropAccumulator.resolve(
                        resolvedURL,
                        at: index,
                        generation: generation
                    ) else { return }

                    pendingDropLoads = []
                    if !selection.isEmpty {
                        coordinator.addSelections(selection)
                    }
                }
            }
        }
        return true
    }

    private func invalidatePendingDrop() {
        pendingDropLoads.forEach { $0.cancel() }
        pendingDropLoads = []
        dropAccumulator.invalidate()
        isDropTargeted = false
    }

    private func revealOutput() {
        guard let outputRoot = coordinator.outputRoot,
              contract.canRevealOutput
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputRoot])
    }

    private func copyDiagnostics() {
        guard contract.canCopyDiagnostics else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let diagnostics = BatchDiagnostics.make(
            version: version,
            build: build,
            phase: coordinator.phase,
            discovery: coordinator.discovery,
            items: coordinator.items
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    private func returnToSingle() {
        guard contract.canReturnToSingle else { return }
        invalidatePendingDrop()
        onReturnToSingle()
    }
}

import AppKit
import LocalOCRCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct LocalOCRStudioView: View {
    @State private var model: StudioViewModel
    private let actions: StudioDocumentActions

    @State private var actionError: StudioPresentedError?
    @State private var isCreatingSearchablePDF = false
    @State private var searchableProgress: StudioProgress?
    @State private var searchablePDFTask: Task<Void, Never>?
    @State private var lifecycle = StudioViewLifecycle()
    @State private var pendingDropLoad: Progress?
    @State private var isDropTargeted = false

    public init(model: StudioViewModel, actions: StudioDocumentActions) {
        self._model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 18) {
            header

            Group {
                switch model.state {
                case .empty:
                    StudioDropZoneView(
                        isTargeted: isDropTargeted,
                        onOpen: showOpenPanel
                    )

                case let .processing(sourceURL, progress):
                    StudioProcessingView(
                        sourceURL: sourceURL,
                        progress: progress,
                        onCancel: model.cancel
                    )

                case let .result(result):
                    StudioResultView(
                        result: result,
                        isCreatingSearchablePDF: isCreatingSearchablePDF,
                        searchableProgress: searchableProgress,
                        onCopy: { actions.copy(result) },
                        onSaveText: { showTextSavePanel(for: result) },
                        onCreateSearchablePDF: { showSearchablePDFSavePanel(for: result) }
                    )

                case let .failure(_, error):
                    StudioErrorView(
                        error: error,
                        onRetry: model.retry,
                        onChooseAnother: showOpenPanel
                    )
                }
            }
            .onDrop(
                of: [UTType.fileURL],
                isTargeted: $isDropTargeted,
                perform: acceptDrop
            )
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            actionError?.title ?? "Action Failed",
            isPresented: actionErrorIsPresented
        ) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            if let actionError {
                Text(alertMessage(for: actionError))
            }
        }
        .onDisappear {
            lifecycle.invalidateForDisappearance()
            pendingDropLoad?.cancel()
            pendingDropLoad = nil
            actionError = nil
            isCreatingSearchablePDF = false
            searchableProgress = nil
            let task = searchablePDFTask
            searchablePDFTask = nil
            task?.cancel()
            model.clear()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalOCR Studio")
                    .font(.system(.title2, design: .rounded, weight: .semibold))

                Text("Readable text from documents, without the cloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Documents stay on this Mac", systemImage: "lock.shield.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { isPresented in
                if !isPresented {
                    actionError = nil
                }
            }
        )
    }

    private func showOpenPanel() {
        lifecycle.invalidatePendingInput()
        pendingDropLoad?.cancel()
        pendingDropLoad = nil

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        open(sourceURL)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1,
              let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        else {
            return false
        }

        pendingDropLoad?.cancel()
        let inputGeneration = lifecycle.beginPendingInput()
        pendingDropLoad = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { data, _ in
            guard let data,
                  let sourceURL = URL(dataRepresentation: data, relativeTo: nil),
                  sourceURL.isFileURL
            else {
                return
            }

            Task { @MainActor in
                lifecycle.resolveInput(sourceURL, for: inputGeneration) { resolvedURL in
                    pendingDropLoad = nil
                    open(resolvedURL)
                }
            }
        }

        return true
    }

    private func open(_ sourceURL: URL) {
        lifecycle.invalidateForOpen()
        pendingDropLoad?.cancel()
        pendingDropLoad = nil
        actionError = nil
        isCreatingSearchablePDF = false
        searchableProgress = nil
        let task = searchablePDFTask
        searchablePDFTask = nil
        task?.cancel()
        model.open(sourceURL)
    }

    private func showTextSavePanel(for result: StudioDocumentResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = actions.suggestedTextFilename(for: result)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        guard !isSource(destinationURL, for: result) else {
            actionError = StudioErrorPresentation.present(LocalOCRError.invalidDestination)
            return
        }

        do {
            try actions.saveText(result, to: destinationURL)
        } catch {
            actionError = StudioErrorPresentation.present(error)
        }
    }

    private func showSearchablePDFSavePanel(for result: StudioDocumentResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = actions.suggestedSearchableFilename(for: result)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        guard !isSource(destinationURL, for: result) else {
            actionError = StudioErrorPresentation.present(LocalOCRError.invalidDestination)
            return
        }

        let searchableAction = lifecycle.beginSearchableAction()
        isCreatingSearchablePDF = true
        searchableProgress = .inspecting

        searchablePDFTask = Task {
            defer {
                lifecycle.finishSearchableAction(searchableAction) {
                    isCreatingSearchablePDF = false
                    searchableProgress = nil
                    searchablePDFTask = nil
                }
            }

            do {
                _ = try await actions.createSearchablePDF(
                    result,
                    at: destinationURL
                ) { progress in
                    Task { @MainActor in
                        lifecycle.publishSearchableProgress(
                            progress,
                            for: searchableAction
                        ) {
                            searchableProgress = $0
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                lifecycle.publishSearchableError(error, for: searchableAction) {
                    actionError = $0
                }
            }
        }
    }

    private func isSource(_ destinationURL: URL, for result: StudioDocumentResult) -> Bool {
        destinationURL.standardizedFileURL.resolvingSymlinksInPath()
            == result.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func alertMessage(for error: StudioPresentedError) -> String {
        guard let details = error.details else {
            return error.message
        }
        return "\(error.message)\n\n\(details)"
    }
}

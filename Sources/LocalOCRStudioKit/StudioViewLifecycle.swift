import Foundation
import LocalOCRCore

@MainActor
final class StudioViewLifecycle {
    private var inputGeneration = UUID()
    private var searchableGeneration = UUID()
    private var intelligenceResultIdentity: String?

    func synchronizeIntelligenceResult(
        identity: String?,
        install: () -> Void,
        clear: () -> Void
    ) {
        guard intelligenceResultIdentity != identity else { return }
        intelligenceResultIdentity = identity
        if identity == nil {
            clear()
        } else {
            install()
        }
    }

    func invalidateIntelligenceResult() {
        intelligenceResultIdentity = nil
    }

    func beginPendingInput() -> UUID {
        let generation = UUID()
        inputGeneration = generation
        return generation
    }

    func invalidatePendingInput() {
        inputGeneration = UUID()
    }

    func invalidateForOpen() {
        inputGeneration = UUID()
        searchableGeneration = UUID()
        intelligenceResultIdentity = nil
    }

    func invalidateForReset() {
        inputGeneration = UUID()
        searchableGeneration = UUID()
        intelligenceResultIdentity = nil
    }

    func performReset(
        cleanup: () -> Void,
        clearModel: () -> Void
    ) {
        invalidateForReset()
        cleanup()
        clearModel()
    }

    func invalidateForDisappearance() {
        inputGeneration = UUID()
        searchableGeneration = UUID()
        intelligenceResultIdentity = nil
    }

    func resolveInput(
        _ sourceURL: URL,
        for generation: UUID,
        open: (URL) -> Void
    ) {
        guard inputGeneration == generation else { return }
        open(sourceURL)
    }

    func beginSearchableAction() -> UUID {
        let generation = UUID()
        searchableGeneration = generation
        return generation
    }

    func publishSearchableProgress(
        _ progress: StudioProgress,
        for generation: UUID,
        deliver: (StudioProgress) -> Void
    ) {
        guard searchableGeneration == generation else { return }
        deliver(progress)
    }

    func publishSearchableError(
        _ error: any Error,
        for generation: UUID,
        deliver: (StudioPresentedError) -> Void
    ) {
        if error is CancellationError {
            return
        }
        if let error = error as? LocalOCRError, error == .cancelled {
            return
        }

        guard searchableGeneration == generation else { return }
        deliver(StudioErrorPresentation.present(error))
    }

    func finishSearchableAction(
        _ generation: UUID,
        deliver: () -> Void
    ) {
        guard searchableGeneration == generation else { return }
        searchableGeneration = UUID()
        deliver()
    }
}

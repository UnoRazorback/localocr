import Foundation
import LocalOCRCore

@MainActor
final class StudioViewLifecycle {
    private var inputGeneration = UUID()
    private var searchableGeneration = UUID()

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
    }

    func invalidateForReset() {
        inputGeneration = UUID()
        searchableGeneration = UUID()
    }

    func invalidateForDisappearance() {
        inputGeneration = UUID()
        searchableGeneration = UUID()
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

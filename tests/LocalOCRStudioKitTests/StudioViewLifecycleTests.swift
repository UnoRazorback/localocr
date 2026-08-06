import Foundation
import LocalOCRCore
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioViewLifecycleTests {
    @Test @MainActor func currentPendingDropOpensItsResolvedFile() {
        let lifecycle = StudioViewLifecycle()
        let sourceURL = URL(fileURLWithPath: "/tmp/current.pdf")
        let drop = lifecycle.beginPendingInput()
        var openedURLs: [URL] = []

        lifecycle.resolveInput(sourceURL, for: drop) { openedURLs.append($0) }

        #expect(openedURLs == [sourceURL])
    }

    @Test @MainActor func pendingDropCannotWinAfterANewerOpen() {
        let lifecycle = StudioViewLifecycle()
        let staleURL = URL(fileURLWithPath: "/tmp/stale.pdf")
        let drop = lifecycle.beginPendingInput()
        var openedURLs: [URL] = []

        lifecycle.invalidateForOpen()
        lifecycle.resolveInput(staleURL, for: drop) { openedURLs.append($0) }

        #expect(openedURLs.isEmpty)
    }

    @Test @MainActor func pendingDropCannotOpenAfterDisappearance() {
        let lifecycle = StudioViewLifecycle()
        let staleURL = URL(fileURLWithPath: "/tmp/closed.pdf")
        let drop = lifecycle.beginPendingInput()
        var openedURLs: [URL] = []

        lifecycle.invalidateForDisappearance()
        lifecycle.resolveInput(staleURL, for: drop) { openedURLs.append($0) }

        #expect(openedURLs.isEmpty)
    }

    @Test @MainActor func activeSearchableCallbacksAreDelivered() {
        let lifecycle = StudioViewLifecycle()
        let searchableAction = lifecycle.beginSearchableAction()
        var progresses: [StudioProgress] = []
        var didFinish = false

        lifecycle.publishSearchableProgress(.assembling, for: searchableAction) {
            progresses.append($0)
        }
        lifecycle.finishSearchableAction(searchableAction) {
            didFinish = true
        }

        #expect(progresses == [.assembling])
        #expect(didFinish)
    }

    @Test @MainActor func disappearanceInvalidatesSearchableCallbacks() {
        let lifecycle = StudioViewLifecycle()
        let searchableAction = lifecycle.beginSearchableAction()
        var progresses: [StudioProgress] = []
        var errors: [StudioPresentedError] = []
        var didFinish = false

        lifecycle.invalidateForDisappearance()
        lifecycle.publishSearchableProgress(.assembling, for: searchableAction) {
            progresses.append($0)
        }
        lifecycle.publishSearchableError(FixtureError.failed, for: searchableAction) {
            errors.append($0)
        }
        lifecycle.finishSearchableAction(searchableAction) {
            didFinish = true
        }

        #expect(progresses.isEmpty)
        #expect(errors.isEmpty)
        #expect(didFinish == false)
    }

    @Test @MainActor func serviceCancellationDoesNotBecomeAnActionError() {
        let lifecycle = StudioViewLifecycle()
        let searchableAction = lifecycle.beginSearchableAction()
        var errors: [StudioPresentedError] = []

        lifecycle.publishSearchableError(LocalOCRError.cancelled, for: searchableAction) {
            errors.append($0)
        }

        #expect(errors.isEmpty)
    }

    @Test @MainActor func activeSearchableFailureUsesSafePresentation() {
        let lifecycle = StudioViewLifecycle()
        let searchableAction = lifecycle.beginSearchableAction()
        var errors: [StudioPresentedError] = []

        lifecycle.publishSearchableError(LocalOCRError.outputExists, for: searchableAction) {
            errors.append($0)
        }

        #expect(errors == [
            StudioPresentedError(
                title: "Output Already Exists",
                message: "Choose a new name or destination for the output file.",
                details: nil
            )
        ])
    }
}

private enum FixtureError: Error {
    case failed
}

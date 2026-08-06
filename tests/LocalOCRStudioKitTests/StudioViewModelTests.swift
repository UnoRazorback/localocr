import Foundation
import LocalOCRCore
import LocalOCRStudioKit
import Testing

@Suite struct StudioViewModelTests {
    @Test @MainActor func startsEmpty() {
        let viewModel = StudioViewModel(client: ControlledStudioClient())

        #expect(viewModel.state == .empty)
    }

    @Test @MainActor func openingAFileMovesFromProcessingToResult() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(sourceURL)
        await client.waitForRequest(at: sourceURL)

        #expect(viewModel.state == .processing(sourceURL: sourceURL, progress: .inspecting))

        let expectedResult = result(for: sourceURL, text: "Coffee $4.50")
        await client.succeed(sourceURL, with: expectedResult)
        await flushStateUpdates()

        #expect(viewModel.state == .result(expectedResult))
    }

    @Test @MainActor func progressUpdatesTheCurrentProcessingState() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/progress.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(sourceURL)
        await client.waitForRequest(at: sourceURL)
        await client.sendProgress(.recognizing(page: 2, total: 3), for: sourceURL)
        await flushStateUpdates()

        #expect(viewModel.state == .processing(
            sourceURL: sourceURL,
            progress: .recognizing(page: 2, total: 3)
        ))
    }

    @Test @MainActor func openingASecondFileCancelsTheFirst() async {
        let firstURL = URL(fileURLWithPath: "/tmp/first.pdf")
        let secondURL = URL(fileURLWithPath: "/tmp/second.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(firstURL)
        await client.waitForRequest(at: firstURL)
        viewModel.open(secondURL)
        await client.waitForRequest(at: secondURL)
        await client.waitForCancellation(at: firstURL)

        #expect(viewModel.state == .processing(sourceURL: secondURL, progress: .inspecting))
    }

    @Test @MainActor func lateFirstResultCannotReplaceTheSecondResult() async {
        let firstURL = URL(fileURLWithPath: "/tmp/first.pdf")
        let secondURL = URL(fileURLWithPath: "/tmp/second.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(firstURL)
        await client.waitForRequest(at: firstURL)
        viewModel.open(secondURL)
        await client.waitForRequest(at: secondURL)

        await client.succeed(firstURL, with: result(for: firstURL, text: "Old document"))
        await flushStateUpdates()

        #expect(viewModel.state == .processing(sourceURL: secondURL, progress: .inspecting))

        let currentResult = result(for: secondURL, text: "Current document")
        await client.succeed(secondURL, with: currentResult)
        await flushStateUpdates()

        #expect(viewModel.state == .result(currentResult))
    }

    @Test @MainActor func cancelReturnsToEmptyWithoutShowingAnError() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/cancel.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(sourceURL)
        await client.waitForRequest(at: sourceURL)
        viewModel.cancel()
        await client.waitForCancellation(at: sourceURL)
        await flushStateUpdates()

        #expect(viewModel.state == .empty)
    }

    @Test @MainActor func clearRemovesTheVisibleResultAndSourceReference() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/clear.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(sourceURL)
        await client.waitForRequest(at: sourceURL)
        await client.succeed(sourceURL, with: result(for: sourceURL, text: "Clear me"))
        await flushStateUpdates()

        viewModel.clear()
        viewModel.retry()
        await flushStateUpdates()

        #expect(viewModel.state == .empty)
        #expect(await client.requestedURLs() == [sourceURL])
    }

    @Test @MainActor func failureContainsCurrentSourceAndPresentedErrorWithoutPriorResult() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/missing.pdf")
        let client = ControlledStudioClient()
        let viewModel = StudioViewModel(client: client)

        viewModel.open(sourceURL)
        await client.waitForRequest(at: sourceURL)
        await client.fail(sourceURL, with: LocalOCRError.fileNotFound)
        await flushStateUpdates()

        #expect(viewModel.state == .failure(
            sourceURL: sourceURL,
            StudioPresentedError(
                title: "File Not Found",
                message: "The selected document is no longer available.",
                details: nil
            )
        ))
    }
}

private actor ControlledStudioClient: StudioOCRClient {
    private var continuations: [URL: CheckedContinuation<StudioDocumentResult, any Error>] = [:]
    private var progressHandlers: [URL: @Sendable (StudioProgress) -> Void] = [:]
    private var requests: [URL] = []
    private var cancellations: Set<URL> = []
    private var requestWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func processDocument(
        at sourceURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        requests.append(sourceURL)
        progressHandlers[sourceURL] = progress

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                continuations[sourceURL] = continuation
                resumeRequestWaiters(for: sourceURL)
            }
        }, onCancel: {
            Task { await self.recordCancellation(for: sourceURL) }
        })
    }

    func makeSearchablePDF(
        sourceURL _: URL,
        destinationURL _: URL,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        throw LocalOCRError.invalidDestination
    }

    func waitForRequest(at sourceURL: URL) async {
        guard !requests.contains(sourceURL) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[sourceURL, default: []].append(continuation)
        }
    }

    func waitForCancellation(at sourceURL: URL) async {
        guard !cancellations.contains(sourceURL) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[sourceURL, default: []].append(continuation)
        }
    }

    func sendProgress(_ progress: StudioProgress, for sourceURL: URL) {
        progressHandlers[sourceURL]?(progress)
    }

    func succeed(_ sourceURL: URL, with result: StudioDocumentResult) {
        continuations.removeValue(forKey: sourceURL)?.resume(returning: result)
    }

    func fail(_ sourceURL: URL, with error: any Error) {
        continuations.removeValue(forKey: sourceURL)?.resume(throwing: error)
    }

    func requestedURLs() -> [URL] { requests }

    private func recordCancellation(for sourceURL: URL) {
        cancellations.insert(sourceURL)
        let waiters = cancellationWaiters.removeValue(forKey: sourceURL) ?? []
        waiters.forEach { $0.resume() }
    }

    private func resumeRequestWaiters(for sourceURL: URL) {
        let waiters = requestWaiters.removeValue(forKey: sourceURL) ?? []
        waiters.forEach { $0.resume() }
    }

}

private func result(for sourceURL: URL, text: String) -> StudioDocumentResult {
    StudioDocumentResult(
        sourceURL: sourceURL,
        sourceSHA256: "test-hash",
        kind: .pdf,
        pageCount: 1,
        searchablePages: 0,
        ocrNeededPages: 1,
        text: text,
        failedPages: []
    )
}

@MainActor
private func flushStateUpdates() async {
    await Task.yield()
    await Task.yield()
}

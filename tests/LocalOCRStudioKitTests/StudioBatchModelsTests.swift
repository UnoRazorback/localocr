import Foundation
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioBatchModelsTests {
    @Test func summaryCountsEveryTerminalState() {
        let items = [
            item(state: .completed(URL(fileURLWithPath: "/out/a_searchable.pdf"))),
            item(state: .failed(.init(title: "OCR Failed", message: "Could not recognize this file.", details: nil))),
            item(state: .cancelled),
        ]
        let summary = StudioBatchSummary(items: items, skippedCount: 2)

        #expect(summary.completed == 1)
        #expect(summary.failed == 1)
        #expect(summary.cancelled == 1)
        #expect(summary.skipped == 2)
    }

    @Test func summaryAddsSkippedItemStatesToDiscoverySkippedCount() {
        let items = [
            item(state: .skipped(.init(title: "Unsupported", message: "Not a supported document.", details: nil))),
            item(state: .queued),
        ]
        let summary = StudioBatchSummary(items: items, skippedCount: 2)

        #expect(summary.skipped == 3)
    }

    @Test func onlyFailedItemsAreRetryable() {
        #expect(StudioBatchItemState.failed(.init(title: "Failed", message: "x", details: nil)).isRetryable)
        #expect(!StudioBatchItemState.cancelled.isRetryable)
        #expect(!StudioBatchItemState.queued.isRetryable)
    }

    @Test func terminalStateIncludesOnlyCompletedSkippedFailedAndCancelledItems() {
        #expect(!StudioBatchItemState.queued.isTerminal)
        #expect(!StudioBatchItemState.processing(.inspecting).isTerminal)
        #expect(StudioBatchItemState.completed(URL(fileURLWithPath: "/out/a_searchable.pdf")).isTerminal)
        #expect(StudioBatchItemState.skipped(.init(title: "Unsupported", message: "x", details: nil)).isTerminal)
        #expect(StudioBatchItemState.failed(.init(title: "Failed", message: "x", details: nil)).isTerminal)
        #expect(StudioBatchItemState.cancelled.isTerminal)
    }

    @Test func reservationRetainsFinalURLAndPhysicalOutputRoot() {
        let finalURL = URL(fileURLWithPath: "/output/job/a_searchable.pdf")
        let outputRoot = URL(fileURLWithPath: "/output")
        let reservation = StudioBatchReservation(finalURL: finalURL, outputRoot: outputRoot)

        #expect(reservation.finalURL == finalURL)
        #expect(reservation.outputRoot == outputRoot)
    }

    @Test func reservationResolvesAndStandardizesPhysicalOutputRoot() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("StudioBatchModelsTests-\(UUID().uuidString)", isDirectory: true)
        let physicalRoot = temporaryRoot.appendingPathComponent("physical-output", isDirectory: true)
        let symlinkRoot = temporaryRoot.appendingPathComponent("output-link", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: physicalRoot)

        let reservation = StudioBatchReservation(
            finalURL: physicalRoot.appendingPathComponent("a_searchable.pdf"),
            outputRoot: symlinkRoot.appendingPathComponent(".", isDirectory: true)
        )

        #expect(reservation.outputRoot == physicalRoot.standardizedFileURL)
    }
}

private func item(state: StudioBatchItemState) -> StudioBatchItem {
    let sourceURL = URL(fileURLWithPath: "/input/a.pdf")
    return StudioBatchItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        candidate: StudioBatchCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sourceURL: sourceURL,
            standardizedSourceURL: sourceURL.standardizedFileURL,
            kind: .pdf,
            relativePath: "a.pdf",
            outputGroupName: nil
        ),
        reservation: StudioBatchReservation(
            finalURL: URL(fileURLWithPath: "/output/a_searchable.pdf"),
            outputRoot: URL(fileURLWithPath: "/output")
        ),
        state: state
    )
}

import Darwin
import CoreGraphics
import Foundation
import LocalOCRCore
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioBatchExecutorTests {
    @Test func imageWritesExactUTF8TextAndReturnsReservedURL() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(kind: .image, text: "Café ☕️")
        let executor = StudioBatchExecutor(client: client)

        let outputURL = try await executor.execute(fixture.item) { _ in }

        #expect(outputURL == fixture.finalURL)
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "Café ☕️")
        #expect(await client.searchableRequests().isEmpty)
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
        #expect(try partialEntries(in: fixture.finalURL.deletingLastPathComponent()).isEmpty)
    }

    @Test func pdfProcessesThenCreatesAValidSearchablePDFAtTheReservedURL() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(kind: .pdf, pdfOutput: .valid)
        let executor = StudioBatchExecutor(client: client)

        let outputURL = try await executor.execute(fixture.item) { _ in }

        #expect(outputURL == fixture.finalURL)
        #expect(await client.operations() == [.process, .searchable])
        #expect(await client.searchableRequests().count == 1)
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
        #expect(try partialEntries(in: fixture.finalURL.deletingLastPathComponent()).isEmpty)
    }

    @Test func forwardsProgressFromBothPDFClientOperations() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let progress = LockedProgress()
        let executor = StudioBatchExecutor(
            client: ExecutorRecordingClient(kind: .pdf, pdfOutput: .valid)
        )

        _ = try await executor.execute(fixture.item, progress: progress.record)

        #expect(progress.values == [.inspecting, .recognizing(page: 1, total: 1), .assembling])
    }

    @Test func createsMissingParentDirectoriesWithoutTouchingTheInput() async throws {
        let fixture = try BatchExecutorFixture(
            kind: .image,
            outputName: "nested/deeper/photo.txt"
        )
        defer { fixture.remove() }
        let executor = StudioBatchExecutor(
            client: ExecutorRecordingClient(kind: .image, text: "recognized")
        )

        _ = try await executor.execute(fixture.item) { _ in }

        #expect(try fixture.finalURL.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory == true)
        #expect(try Data(contentsOf: fixture.sourceURL) == fixture.sourceData)
    }

    @Test func rejectsAReservedFinalOutsideThePhysicalRoot() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let outsideURL = fixture.baseURL.appending(path: "outside.txt")
        let item = fixture.item(reservation: StudioBatchReservation(
            finalURL: outsideURL,
            outputRoot: fixture.outputRoot
        ))
        let executor = StudioBatchExecutor(client: ExecutorRecordingClient(kind: .image))

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await executor.execute(item) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: outsideURL.path))
    }

    @Test func rejectsAnExistingSymbolicLinkAncestor() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "linked/photo.txt")
        defer { fixture.remove() }
        let external = fixture.baseURL.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.outputRoot.appending(path: "linked"),
            withDestinationURL: external
        )
        let executor = StudioBatchExecutor(client: ExecutorRecordingClient(kind: .image))

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await executor.execute(fixture.item) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "photo.txt").path))
    }

    @Test func rejectsANonDirectoryAncestor() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "blocked/photo.txt")
        defer { fixture.remove() }
        try Data("file".utf8).write(to: fixture.outputRoot.appending(path: "blocked"))
        let executor = StudioBatchExecutor(client: ExecutorRecordingClient(kind: .image))

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await executor.execute(fixture.item) { _ in }
        }
    }

    @Test func rejectsAnOutputRootReplacedAfterTemporaryReservation() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        let movedRoot = fixture.baseURL.appending(path: "moved-root", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: fixture.outputRoot, to: movedRoot)
        try FileManager.default.createDirectory(at: fixture.outputRoot, withIntermediateDirectories: false)

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.writeText(
                "unsafe",
                to: temporaryURL,
                outputRoot: fixture.outputRoot
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    @Test func rejectsASymbolicLinkOutputRoot() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let linkedRoot = fixture.baseURL.appending(path: "linked-output", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.outputRoot)
        let linkedFinal = linkedRoot.appending(path: "photo.txt")
        let committer = AtomicStudioBatchOutputCommitter()

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.temporaryURL(for: linkedFinal, outputRoot: linkedRoot)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    @Test func rejectsAnAncestorSwappedToASymbolicLinkBeforeWriting() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "nested/photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        let parent = fixture.finalURL.deletingLastPathComponent()
        let movedParent = fixture.baseURL.appending(path: "moved-parent", directoryHint: .isDirectory)
        let external = fixture.baseURL.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.writeText(
                "unsafe",
                to: temporaryURL,
                outputRoot: fixture.outputRoot
            )
        }

        #expect(!FileManager.default.fileExists(atPath: external.appending(path: temporaryURL.lastPathComponent).path))
    }

    @Test func rejectsAnAncestorSwappedToASymbolicLinkBeforeCommit() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "nested/photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try await committer.writeText(
            "recognized",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )
        let parent = fixture.finalURL.deletingLastPathComponent()
        let movedParent = fixture.baseURL.appending(path: "commit-parent", directoryHint: .isDirectory)
        let external = fixture.baseURL.appending(path: "commit-external", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }

        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "photo.txt").path))
        #expect(try String(
            contentsOf: movedParent
                .appending(path: temporaryURL.deletingLastPathComponent().lastPathComponent)
                .appending(path: temporaryURL.lastPathComponent),
            encoding: .utf8
        ) == "recognized")
    }

    @Test func retriesAReservedTemporaryNameThatAlreadyExists() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let names = LockedNames(["occupied.partial", "available.partial"])
        try Data("do not replace".utf8).write(
            to: fixture.outputRoot.appending(path: "occupied.partial")
        )
        let committer = AtomicStudioBatchOutputCommitter(
            temporaryName: { _ in names.next() }
        )

        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )

        #expect(temporaryURL.lastPathComponent == fixture.finalURL.lastPathComponent)
        #expect(temporaryURL.deletingLastPathComponent().lastPathComponent == "available.partial")
        #expect(temporaryURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "output")
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(try FileManager.default.attributesOfItem(
            atPath: temporaryURL.deletingLastPathComponent().path
        )[.posixPermissions] as? Int == 0o700)
        #expect(try deviceID(of: temporaryURL.deletingLastPathComponent()) == deviceID(
            of: fixture.finalURL.deletingLastPathComponent()
        ))
        #expect(try String(
            contentsOf: fixture.outputRoot.appending(path: "occupied.partial"),
            encoding: .utf8
        ) == "do not replace")
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)
    }

    @Test func discardPreservesAnUnownedPostReservationCollision() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try Data("peer collision".utf8).write(to: temporaryURL)

        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(try String(contentsOf: temporaryURL, encoding: .utf8) == "peer collision")
    }

    @Test func commitRejectsAndPreservesALeafSubstitutedAfterOwnership() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try await committer.writeText(
            "owned",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )
        try FileManager.default.removeItem(at: temporaryURL)
        try Data("peer replacement".utf8).write(to: temporaryURL)

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try String(contentsOf: temporaryURL, encoding: .utf8) == "peer replacement")
    }

    @Test func discardCleansOwnedOutputThroughRetainedDescriptorsAfterAncestorReplacement() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "nested/photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try await committer.writeText(
            "owned",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )
        let originalParent = fixture.finalURL.deletingLastPathComponent()
        let movedParent = fixture.baseURL.appending(path: "cleanup-parent", directoryHint: .isDirectory)
        let external = fixture.baseURL.appending(path: "cleanup-external", directoryHint: .isDirectory)
        let movedStagingURL = movedParent.appending(
            path: temporaryURL.deletingLastPathComponent().lastPathComponent,
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: originalParent, to: movedParent)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: external)

        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(!FileManager.default.fileExists(atPath: movedStagingURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func textCreationReprovesAncestorsAfterItsPreMutationProof() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "nested/photo.txt")
        defer { fixture.remove() }
        let originalParent = fixture.finalURL.deletingLastPathComponent()
        let movedParent = fixture.baseURL.appending(path: "proof-parent", directoryHint: .isDirectory)
        let external = fixture.baseURL.appending(path: "proof-external", directoryHint: .isDirectory)
        let mutation = OneShotAsyncMutation {
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: external)
        }
        let committer = AtomicStudioBatchOutputCommitter(
            beforeTextCreation: mutation.run
        )
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.writeText(
                "must not escape",
                to: temporaryURL,
                outputRoot: fixture.outputRoot
            )
        }
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func commitReprovesOwnedLeafAfterValidationBeforeExclusiveRename() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let temporaryBox = LockedURL()
        let mutation = OneShotAsyncMutation {
            let temporaryURL = try #require(temporaryBox.value)
            try FileManager.default.removeItem(at: temporaryURL)
            try Data("peer replacement".utf8).write(to: temporaryURL)
        }
        let committer = AtomicStudioBatchOutputCommitter(
            beforeExclusiveCommit: mutation.run
        )
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        temporaryBox.value = temporaryURL
        try await committer.writeText(
            "owned",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try String(contentsOf: temporaryURL, encoding: .utf8) == "peer replacement")
    }

    @Test func commitReprovesAncestorsAfterValidationBeforeExclusiveRename() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "nested/photo.txt")
        defer { fixture.remove() }
        let originalParent = fixture.finalURL.deletingLastPathComponent()
        let movedParent = fixture.baseURL.appending(path: "linear-parent", directoryHint: .isDirectory)
        let external = fixture.baseURL.appending(path: "linear-external", directoryHint: .isDirectory)
        let mutation = OneShotAsyncMutation {
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: external)
        }
        let committer = AtomicStudioBatchOutputCommitter(
            beforeExclusiveCommit: mutation.run
        )
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        let movedStagingURL = movedParent.appending(
            path: temporaryURL.deletingLastPathComponent().lastPathComponent,
            directoryHint: .isDirectory
        )
        try await committer.writeText(
            "owned",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)

        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: movedStagingURL.path))
    }

    @Test func cancellationWhileCommitIsQueuedStopsBeforeExclusiveRename() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let barrier = SuspendingCommitBarrier()
        let committer = AtomicStudioBatchOutputCommitter(
            beforeExclusiveCommit: barrier.suspend
        )
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try await committer.writeText(
            "owned",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )
        let commitTask = Task {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }
        await barrier.waitUntilSuspended()

        commitTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await commitTask.value
        }
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test func invalidPDFOutputFailsValidationAndCleansTheTemporaryFile() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let executor = StudioBatchExecutor(
            client: ExecutorRecordingClient(kind: .pdf, pdfOutput: .invalid)
        )

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await executor.execute(fixture.item) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func pdfClientThrowPreservesAnUnownedCollision() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(kind: .pdf, pdfOutput: .collisionThenThrows)
        let executor = StudioBatchExecutor(client: client)

        await #expect(throws: LocalOCRError.outputExists) {
            try await executor.execute(fixture.item) { _ in }
        }

        let request = try #require(await client.searchableRequests().first)
        #expect(try String(contentsOf: request.1, encoding: .utf8) == "peer collision")
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    @Test func searchableClientMustReturnTheExactTemporaryURL() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let executor = StudioBatchExecutor(
            client: ExecutorRecordingClient(kind: .pdf, pdfOutput: .returnsWrongURL)
        )

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await executor.execute(fixture.item) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func symbolicLinkPDFOutputFailsValidationWithoutDeletingItsTarget() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let externalPDF = fixture.baseURL.appending(path: "external.pdf")
        try writeValidPDF(to: externalPDF)
        let executor = StudioBatchExecutor(
            client: ExecutorRecordingClient(kind: .pdf, pdfOutput: .symbolicLink(externalPDF))
        )

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await executor.execute(fixture.item) { _ in }
        }

        #expect(FileManager.default.fileExists(atPath: externalPDF.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func finalCollisionAtCommitMapsToOutputExistsAndNeverReplaces() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let committer = AtomicStudioBatchOutputCommitter()
        let temporaryURL = try await committer.temporaryURL(
            for: fixture.finalURL,
            outputRoot: fixture.outputRoot
        )
        try await committer.writeText(
            "recognized",
            to: temporaryURL,
            outputRoot: fixture.outputRoot
        )
        try Data("external winner".utf8).write(to: fixture.finalURL)

        await #expect(throws: LocalOCRError.outputExists) {
            try await committer.commit(
                temporaryURL,
                to: fixture.finalURL,
                outputRoot: fixture.outputRoot
            )
        }

        #expect(try String(contentsOf: fixture.finalURL, encoding: .utf8) == "external winner")
        await committer.discard(temporaryURL, outputRoot: fixture.outputRoot)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test func cancellationBeforeExecutionDoesNotCallTheClientOrCreateOutput() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(kind: .image)
        let executor = StudioBatchExecutor(client: client)
        let task = Task { try await executor.execute(fixture.item) { _ in } }
        task.cancel()

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }

        #expect(await client.operations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    @Test func cancellationDuringClientProcessingCleansTemporaryOutput() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let client = SuspendingExecutorClient(kind: .image, suspendAt: .process)
        let executor = StudioBatchExecutor(client: client)
        let task = Task { try await executor.execute(fixture.item) { _ in } }
        await client.waitUntilSuspended()

        task.cancel()

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func cancellationDuringSearchablePDFCreationCleansTemporaryOutput() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let client = SuspendingExecutorClient(kind: .pdf, suspendAt: .searchable)
        let executor = StudioBatchExecutor(client: client)
        let task = Task { try await executor.execute(fixture.item) { _ in } }
        await client.waitUntilSuspended()

        task.cancel()

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func cancellationAfterImageClientReturnsPreventsWriting() async throws {
        let fixture = try BatchExecutorFixture(kind: .image, outputName: "photo.txt")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(kind: .image, cancelAfterProcess: true)
        let executor = StudioBatchExecutor(client: client)
        let task = Task { try await executor.execute(fixture.item) { _ in } }

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }

    @Test func cancellationAfterSearchableClientReturnsPreventsCommit() async throws {
        let fixture = try BatchExecutorFixture(kind: .pdf, outputName: "scan_searchable.pdf")
        defer { fixture.remove() }
        let client = ExecutorRecordingClient(
            kind: .pdf,
            pdfOutput: .valid,
            cancelAfterSearchable: true
        )
        let executor = StudioBatchExecutor(client: client)
        let task = Task { try await executor.execute(fixture.item) { _ in } }

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalURL.path))
        #expect(try partialEntries(in: fixture.outputRoot).isEmpty)
    }
}

private struct BatchExecutorFixture {
    let baseURL: URL
    let outputRoot: URL
    let sourceURL: URL
    let sourceData = Data("original input".utf8)
    let finalURL: URL
    let item: StudioBatchItem

    init(kind: StudioDocumentKind, outputName: String) throws {
        baseURL = FileManager.default.temporaryDirectory.appending(
            path: "StudioBatchExecutorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        outputRoot = baseURL.appending(path: "output", directoryHint: .isDirectory)
        sourceURL = baseURL.appending(path: kind == .pdf ? "source.pdf" : "source.png")
        finalURL = outputRoot.appending(path: outputName)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try sourceData.write(to: sourceURL)
        let candidate = StudioBatchCandidate(
            id: UUID(),
            sourceURL: sourceURL,
            standardizedSourceURL: sourceURL.standardizedFileURL,
            kind: kind,
            relativePath: sourceURL.lastPathComponent,
            outputGroupName: nil
        )
        item = StudioBatchItem(
            id: candidate.id,
            candidate: candidate,
            reservation: StudioBatchReservation(finalURL: finalURL, outputRoot: outputRoot),
            state: .queued
        )
    }

    func item(reservation: StudioBatchReservation) -> StudioBatchItem {
        StudioBatchItem(
            id: item.id,
            candidate: item.candidate,
            reservation: reservation,
            state: .queued
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

private enum RecordedExecutorOperation: Sendable, Equatable {
    case process
    case searchable
}

private enum PDFOutputBehavior: Sendable {
    case valid
    case invalid
    case returnsWrongURL
    case symbolicLink(URL)
    case collisionThenThrows
}

private actor ExecutorRecordingClient: StudioOCRClient {
    private let kind: StudioDocumentKind
    private let text: String
    private let pdfOutput: PDFOutputBehavior
    private let cancelAfterProcess: Bool
    private let cancelAfterSearchable: Bool
    private var recordedOperations: [RecordedExecutorOperation] = []
    private var recordedSearchableRequests: [(URL, URL)] = []

    init(
        kind: StudioDocumentKind,
        text: String = "recognized",
        pdfOutput: PDFOutputBehavior = .valid,
        cancelAfterProcess: Bool = false,
        cancelAfterSearchable: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.pdfOutput = pdfOutput
        self.cancelAfterProcess = cancelAfterProcess
        self.cancelAfterSearchable = cancelAfterSearchable
    }

    func processDocument(
        at sourceURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        recordedOperations.append(.process)
        progress(.inspecting)
        progress(.recognizing(page: 1, total: 1))
        if cancelAfterProcess {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return StudioDocumentResult(
            sourceURL: sourceURL,
            sourceSHA256: "test-hash",
            kind: kind,
            pageCount: 1,
            searchablePages: kind == .pdf ? 1 : 0,
            ocrNeededPages: kind == .image ? 1 : 0,
            text: text,
            failedPages: []
        )
    }

    func makeSearchablePDF(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        recordedOperations.append(.searchable)
        recordedSearchableRequests.append((sourceURL, destinationURL))
        progress(.assembling)
        switch pdfOutput {
        case .valid, .returnsWrongURL:
            try writeValidPDF(to: destinationURL)
        case .invalid:
            try Data("not a PDF".utf8).write(to: destinationURL)
        case let .symbolicLink(targetURL):
            try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: targetURL)
        case .collisionThenThrows:
            try Data("peer collision".utf8).write(to: destinationURL)
            throw LocalOCRError.outputExists
        }
        if cancelAfterSearchable {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if case .returnsWrongURL = pdfOutput {
            return destinationURL.deletingLastPathComponent().appending(path: "wrong.pdf")
        }
        return destinationURL
    }

    func operations() -> [RecordedExecutorOperation] { recordedOperations }
    func searchableRequests() -> [(URL, URL)] { recordedSearchableRequests }
}

private actor SuspendingExecutorClient: StudioOCRClient {
    enum SuspensionPoint: Sendable {
        case process
        case searchable
    }

    private let kind: StudioDocumentKind
    private let suspendAt: SuspensionPoint
    private var isSuspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(kind: StudioDocumentKind, suspendAt: SuspensionPoint) {
        self.kind = kind
        self.suspendAt = suspendAt
    }

    func processDocument(
        at sourceURL: URL,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        if suspendAt == .process {
            announceSuspension()
            try await Task.sleep(for: .seconds(30))
        }
        return StudioDocumentResult(
            sourceURL: sourceURL,
            sourceSHA256: "test-hash",
            kind: kind,
            pageCount: 1,
            searchablePages: kind == .pdf ? 1 : 0,
            ocrNeededPages: kind == .image ? 1 : 0,
            text: "recognized",
            failedPages: []
        )
    }

    func makeSearchablePDF(
        sourceURL _: URL,
        destinationURL: URL,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        if suspendAt == .searchable {
            announceSuspension()
            try await Task.sleep(for: .seconds(30))
        }
        try writeValidPDF(to: destinationURL)
        return destinationURL
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func announceSuspension() {
        isSuspended = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StudioProgress] = []

    var values: [StudioProgress] {
        lock.withLock { storage }
    }

    func record(_ progress: StudioProgress) {
        lock.withLock { storage.append(progress) }
    }
}

private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]

    init(_ names: [String]) {
        self.names = names
    }

    func next() -> String {
        lock.withLock { names.removeFirst() }
    }
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var value: URL? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class OneShotAsyncMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: @Sendable () throws -> Void
    private var hasRun = false

    init(_ operation: @escaping @Sendable () throws -> Void) {
        self.operation = operation
    }

    func run() async throws {
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        if shouldRun {
            try operation()
        }
    }
}

private actor SuspendingCommitBarrier {
    private var isSuspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async throws {
        isSuspended = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(30))
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func partialEntries(in directoryURL: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains("partial") }
}

private func deviceID(of url: URL) throws -> UInt64 {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw LocalOCRError.invalidDestination
    }
    return UInt64(metadata.st_dev)
}

private func writeValidPDF(to destinationURL: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
    guard let consumer = CGDataConsumer(url: destinationURL as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw LocalOCRError.outputValidationFailed
    }
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
}

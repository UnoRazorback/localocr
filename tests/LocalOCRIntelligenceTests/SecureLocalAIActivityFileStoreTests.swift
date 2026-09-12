import Darwin
import Dispatch
import Foundation
@testable import LocalOCRIntelligence
import Testing

@Suite(.serialized) struct SecureLocalAIActivityFileStoreTests {
    @Test func contendedMutationLockFailsBeforeOwnerReleasesIt() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let lockURL = fixture.rootURL.appending(path: "v1/.mutation.lock")
        let owner = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(owner >= 0)
        guard owner >= 0 else { return }
        defer { Darwin.close(owner) }
        #expect(flock(owner, LOCK_EX | LOCK_NB) == 0)
        let result = ContendedActivityWriteResult()
        let completed = DispatchSemaphore(value: 0)
        let id = UUID()
        DispatchQueue.global().async {
            do {
                try fixture.store.atomicallyWrite(Data("record".utf8), id: id, to: .active)
                result.set(nil)
            } catch {
                result.set(error as? SecureLocalAIActivityFileStoreError)
            }
            completed.signal()
        }
        let returnedWhileHeld = completed.wait(timeout: .now() + 1) == .success
        #expect(flock(owner, LOCK_UN) == 0)
        if !returnedWhileHeld { _ = completed.wait(timeout: .now() + 5) }
        #expect(returnedWhileHeld)
        #expect(result.error == .filesystemOperationFailed(EWOULDBLOCK))
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(id: id, in: .active).path))
    }

    @Test func enumerationBoundsValidRecordCollection() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        for _ in 0..<300 {
            try Data().write(to: fixture.recordURL(id: UUID(), in: .active))
        }
        let ids = try fixture.store.recordIDs(in: .active)
        #expect(ids.count <= 256)
        #expect(!ids.isEmpty)
    }

    @Test func enumerationChargesInvalidNamesAgainstTheSameBudget() throws {
        let counter = ActivityEnumerationCounter()
        let fixture = try SecureActivityStoreFixture(hooks: .init(didEnumerateEntry: { counter.increment() }))
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        for index in 0..<300 {
            try Data().write(to: fixture.directoryURL(.active).appending(path: "invalid-\(index)"))
        }
        let ids = try fixture.store.recordIDs(in: .active)
        #expect(ids.isEmpty)
        #expect(counter.value == 256)
    }

    @Test func repeatedBoundedScansEventuallyVisitRecordsBeyondJunk() throws {
        let counter = ActivityEnumerationCounter()
        let fixture = try SecureActivityStoreFixture(hooks: .init(didEnumerateEntry: { counter.increment() }))
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let expected = Set((0..<300).map { _ in UUID() })
        for index in 0..<300 {
            try Data().write(to: fixture.directoryURL(.active).appending(path: "junk-\(index)"))
        }
        for id in expected { try Data().write(to: fixture.recordURL(id: id, in: .active)) }
        var visited: Set<UUID> = []
        for _ in 0..<4 {
            let before = counter.value
            visited.formUnion(try fixture.store.recordIDs(in: .active))
            #expect(counter.value - before <= 256)
        }
        #expect(visited == expected)
    }

    @Test func retainedCursorIsDiscardedWhenLedgerDirectoryIsReplaced() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        for _ in 0..<300 { try Data().write(to: fixture.recordURL(id: UUID(), in: .active)) }
        _ = try fixture.store.recordIDs(in: .active)
        let active = fixture.directoryURL(.active)
        try FileManager.default.moveItem(at: active, to: fixture.rootURL.appending(path: "old-active"))
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let replacementID = UUID()
        try Data().write(to: fixture.recordURL(id: replacementID, in: .active))
        #expect(try fixture.store.recordIDs(in: .active) == [replacementID])
    }

    // Catches missing fixed directories, process-umask-dependent permissions, or omission of backup exclusion.
    @Test func prepareCreatesPrivateFixedTreeExcludedFromBackup() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }

        try fixture.store.prepareLedgerDirectories()

        for component in ["LocalAIActivity", "LocalAIActivity/v1", "LocalAIActivity/v1/active", "LocalAIActivity/v1/recent"] {
            #expect(try fixture.mode(at: fixture.containerURL.appending(path: component, directoryHint: .isDirectory)) == 0o700)
        }
        let values = try fixture.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // Catches partial publication, non-atomic replacement, stale temp files, or a file mode broader than 0600.
    @Test func atomicWritePublishesCompletePrivateReplacement() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let first = Data("first complete record".utf8)
        let second = Data("second complete record".utf8)

        try fixture.store.atomicallyWrite(first, id: id, to: .active)
        let firstSnapshot = try snapshot(from: try fixture.store.readRecord(id: id, from: .active))
        #expect(firstSnapshot.data == first)
        #expect(try fixture.mode(at: fixture.recordURL(id: id, in: .active)) == 0o600)

        try fixture.store.atomicallyWrite(second, id: id, to: .active)
        let secondSnapshot = try snapshot(from: try fixture.store.readRecord(id: id, from: .active))
        #expect(secondSnapshot.data == second)
        #expect(try fixture.directoryNames(.active) == ["\(id.uuidString.lowercased()).json"])
    }

    // Catches a writer that exceeds the strict contract cap or leaves a truncated final file after rejecting it.
    @Test func oversizedWriteIsRejectedWithoutPublishingARecord() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.atomicallyWrite(
                Data(repeating: 0x41, count: LocalAIActivityContract.maximumRecordBytes + 1),
                id: id,
                to: .active
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(id: id, in: .active).path))
        #expect(try fixture.directoryNames(.active).isEmpty)
    }

    // Catches an unbounded reader that allocates the full oversized hostile record before cleanup can compare its version.
    @Test func oversizedReadReturnsOnlyBoundedVersionEvidence() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let url = fixture.recordURL(id: id, in: .active)
        let hostileByteCount = LocalAIActivityContract.maximumRecordBytes + 4_097
        try Data(repeating: 0x41, count: hostileByteCount).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        guard let result = try fixture.store.readRecord(id: id, from: .active) else {
            Issue.record("Expected an oversized record result")
            return
        }
        switch result {
        case let .oversized(version):
            #expect(version.byteCount == Int64(hostileByteCount))
            #expect(version.contentEvidence.count == LocalAIActivityContract.maximumRecordBytes + 1)
        case .record:
            Issue.record("Expected bounded oversized version evidence")
        }
    }

    // Catches following a symlinked fixed ledger directory into an attacker-controlled location.
    @Test func symlinkedLedgerRootCannotEscapeTheContainer() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        let outside = fixture.containerURL.deletingLastPathComponent()
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.rootURL, withDestinationURL: outside)

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.prepareLedgerDirectories()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    // Catches configured-container traversal that would open a sibling instead of the injected container identity.
    @Test func traversalComponentInContainerPathIsRejected() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        let traversalURL = fixture.containerURL
            .appending(path: "child", directoryHint: .isDirectory)
            .appending(path: "..", directoryHint: .isDirectory)
        let store = SecureLocalAIActivityFileStore(containerURL: traversalURL)

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try store.prepareLedgerDirectories()
        }
    }

    // Catches read paths that follow a UUID-named symlink and disclose bytes outside the ledger.
    @Test func recordSymlinkIsRejectedWithoutTouchingItsTarget() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let outside = fixture.containerURL.appending(path: "outside-secret", directoryHint: .notDirectory)
        try Data("private prompt".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.recordURL(id: id, in: .active),
            withDestinationURL: outside
        )

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.readRecord(id: id, from: .active)
        }
        #expect(try Data(contentsOf: outside) == Data("private prompt".utf8))
    }

    // Catches replacement logic that follows or silently accepts a hostile destination symlink.
    @Test func atomicWriteRefusesExistingSymlinkDestination() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let outside = fixture.containerURL.appending(path: "outside-target", directoryHint: .notDirectory)
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.recordURL(id: id, in: .active),
            withDestinationURL: outside
        )

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.atomicallyWrite(Data("replacement".utf8), id: id, to: .active)
        }
        #expect(try Data(contentsOf: outside) == Data("unchanged".utf8))
    }

    // Catches reads that accept a directory, device, or other non-regular UUID entry.
    @Test func nonRegularRecordIsRejected() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        try FileManager.default.createDirectory(at: fixture.recordURL(id: id, in: .active), withIntermediateDirectories: false)

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.readRecord(id: id, from: .active)
        }
    }

    // Catches reads that accept group/world-accessible activity records.
    @Test func insecureRecordModeIsRejected() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let url = fixture.recordURL(id: id, in: .active)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.readRecord(id: id, from: .active)
        }
    }

    // Catches directory validation that checks type and mode but omits owner identity.
    @Test func unexpectedOwnerMakesTheStoreUnavailable() throws {
        let fixture = try SecureActivityStoreFixture(expectedOwnerID: geteuid() &+ 1)
        defer { fixture.remove() }

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.prepareLedgerDirectories()
        }
    }

    // Catches permissive enumeration of uppercase, malformed, hidden, or non-JSON filenames.
    @Test func enumerationReturnsOnlyExactLowercaseUUIDJSONNames() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let acceptedID = UUID()
        try fixture.store.atomicallyWrite(Data("{}".utf8), id: acceptedID, to: .active)
        let rejectedID = UUID()
        let directory = fixture.directoryURL(.active)
        for name in [
            "\(rejectedID.uuidString).json",
            "../escape.json",
            "not-a-uuid.json",
            ".\(UUID().uuidString.lowercased()).temporary",
            "\(UUID().uuidString.lowercased()).txt"
        ] where !name.contains("/") {
            try Data().write(to: directory.appending(path: name, directoryHint: .notDirectory))
        }

        #expect(try fixture.store.recordIDs(in: .active) == [acceptedID])
    }

    // Catches move logic that copies, leaves stale active state, or publishes under a noncanonical filename.
    @Test func atomicMoveRenamesOneCanonicalRecordBetweenFixedDirectories() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let data = Data("complete ended record".utf8)
        try fixture.store.atomicallyWrite(data, id: id, to: .active)

        let activeSnapshot = try snapshot(from: try fixture.store.readRecord(id: id, from: .active))
        #expect(try fixture.store.atomicallyMove(
            id: id,
            from: .active,
            to: .recent,
            expectedVersion: activeSnapshot.version
        ))

        #expect(try fixture.store.readRecord(id: id, from: .active) == nil)
        let movedSnapshot = try snapshot(from: try fixture.store.readRecord(id: id, from: .recent))
        #expect(movedSnapshot.data == data)
    }

    // Catches a stale active-to-recent move that overwrites an independently published recent record.
    @Test func conditionalMovePreservesAnExistingRecentDestination() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let active = Data("ended active record".utf8)
        let recent = Data("existing recent record".utf8)
        try fixture.store.atomicallyWrite(active, id: id, to: .active)
        let activeSnapshot = try snapshot(from: try fixture.store.readRecord(id: id, from: .active))
        try fixture.store.atomicallyWrite(recent, id: id, to: .recent)

        #expect(try !fixture.store.atomicallyMove(
            id: id,
            from: .active,
            to: .recent,
            expectedVersion: activeSnapshot.version
        ))

        #expect(try snapshot(from: fixture.store.readRecord(id: id, from: .active)).data == active)
        #expect(try snapshot(from: fixture.store.readRecord(id: id, from: .recent)).data == recent)
    }

    // Catches ABA reuse where a pathname returns to the same device/inode identity with different immutable bytes.
    @Test func recordVersionDistinguishesReplacementBytesAtTheSameFilesystemIdentity() {
        let original = version(device: 7, inode: 11, evidence: Data("old".utf8))
        let replacement = version(device: 7, inode: 11, evidence: Data("new".utf8))

        #expect(original != replacement)
    }

    // Catches conditional mutations that compare only device/inode and therefore accept an ABA-recycled record identity.
    @Test func conditionalMutationsRejectSameIdentityWithDifferentImmutableEvidence() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let original = Data("original record".utf8)
        try fixture.store.atomicallyWrite(original, id: id, to: .active)
        let originalSnapshot = try snapshot(from: fixture.store.readRecord(id: id, from: .active))
        let staleVersion = version(like: originalSnapshot.version, evidence: Data("replacement record".utf8))

        #expect(try fixture.store.replaceRecord(
            Data("new record".utf8),
            id: id,
            to: .active,
            expectedVersion: staleVersion
        ) == nil)
        #expect(try !fixture.store.atomicallyMove(
            id: id,
            from: .active,
            to: .recent,
            expectedVersion: staleVersion
        ))
        #expect(try !fixture.store.remove(id: id, from: .active, expectedVersion: staleVersion))
        #expect(try snapshot(from: fixture.store.readRecord(id: id, from: .active)).data == original)
        #expect(try fixture.store.readRecord(id: id, from: .recent) == nil)
    }

    // Catches cleanup that trusts a symlinked entry enough to mutate it after validation failed.
    @Test func untrustedSymlinkCannotBeConditionallyRemoved() throws {
        let fixture = try SecureActivityStoreFixture()
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()
        let outside = fixture.containerURL.appending(path: "outside-preserved", directoryHint: .notDirectory)
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.recordURL(id: id, in: .active),
            withDestinationURL: outside
        )

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.readRecord(id: id, from: .active)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.recordURL(id: id, in: .active).path))
        #expect(try Data(contentsOf: outside) == Data("preserve".utf8))
    }

    // Catches publication that proceeds when the complete temporary file cannot be durably synchronized.
    @Test func synchronizationFailurePublishesNoFinalRecord() throws {
        let fixture = try SecureActivityStoreFixture(
            hooks: SecureLocalAIActivityFileStoreHooks(synchronizeDescriptor: { _ in EIO })
        )
        defer { fixture.remove() }
        try fixture.store.prepareLedgerDirectories()
        let id = UUID()

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.atomicallyWrite(Data("complete".utf8), id: id, to: .active)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(id: id, in: .active).path))
    }

    // Catches a reporting source that remains available after backup exclusion could not be applied and verified.
    @Test func backupExclusionFailureMakesPreparationUnavailable() throws {
        let fixture = try SecureActivityStoreFixture(
            hooks: SecureLocalAIActivityFileStoreHooks(applyAndVerifyBackupExclusion: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
        )
        defer { fixture.remove() }

        #expect(throws: SecureLocalAIActivityFileStoreError.self) {
            try fixture.store.prepareLedgerDirectories()
        }
    }
}

private struct SecureActivityStoreFixture {
    let containerURL: URL
    let store: SecureLocalAIActivityFileStore

    init(
        expectedOwnerID: uid_t = geteuid(),
        hooks: SecureLocalAIActivityFileStoreHooks = SecureLocalAIActivityFileStoreHooks()
    ) throws {
        containerURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: false)
        store = SecureLocalAIActivityFileStore(
            containerURL: containerURL,
            expectedOwnerID: expectedOwnerID,
            hooks: hooks
        )
    }

    var rootURL: URL {
        containerURL.appending(path: "LocalAIActivity", directoryHint: .isDirectory)
    }

    func directoryURL(_ directory: LocalAILedgerDirectory) -> URL {
        rootURL
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: directory.rawValue, directoryHint: .isDirectory)
    }

    func recordURL(id: UUID, in directory: LocalAILedgerDirectory) -> URL {
        directoryURL(directory)
            .appending(path: "\(id.uuidString.lowercased()).json", directoryHint: .notDirectory)
    }

    func directoryNames(_ directory: LocalAILedgerDirectory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryURL(directory).path).sorted()
    }

    func mode(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & 0o777
    }

    func remove() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}

private func snapshot(from result: LocalAIActivityRecordReadResult?) throws -> LocalAIActivityRecordSnapshot {
    guard case let .record(snapshot)? = result else {
        throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
    }
    return snapshot
}

private func version(device: UInt64, inode: UInt64, evidence: Data) -> LocalAIActivityRecordVersion {
    LocalAIActivityRecordVersion(
        device: device,
        inode: inode,
        generation: 0,
        byteCount: Int64(evidence.count),
        modifiedSeconds: 0,
        modifiedNanoseconds: 0,
        changedSeconds: 0,
        changedNanoseconds: 0,
        contentEvidence: evidence
    )
}

private func version(
    like version: LocalAIActivityRecordVersion,
    evidence: Data
) -> LocalAIActivityRecordVersion {
    LocalAIActivityRecordVersion(
        device: version.device,
        inode: version.inode,
        generation: version.generation,
        byteCount: version.byteCount,
        modifiedSeconds: version.modifiedSeconds,
        modifiedNanoseconds: version.modifiedNanoseconds,
        changedSeconds: version.changedSeconds,
        changedNanoseconds: version.changedNanoseconds,
        contentEvidence: evidence
    )
}

private final class ContendedActivityWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: SecureLocalAIActivityFileStoreError?
    var error: SecureLocalAIActivityFileStoreError? { lock.withLock { storedError } }
    func set(_ error: SecureLocalAIActivityFileStoreError?) {
        lock.withLock { storedError = error }
    }
}

private final class ActivityEnumerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

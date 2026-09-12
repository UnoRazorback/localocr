import Darwin
import Dispatch
import Foundation
@testable import LocalOCRIntelligence
import Testing

@Suite(.serialized) struct LocalAIActivityLedgerTests {
    private let initialDate = Date(timeIntervalSince1970: 1_788_184_800)

    // Catches a begin path that uses the wrong fixed directory, omits a field, or computes a lease other than 45 seconds.
    @Test func beginWritesActiveRecordWithExactLease() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }

        let id = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))
        let record = try fixture.record(in: .active, id: id)

        #expect(record.activityID == id)
        #expect(record.producerRole == .studio)
        #expect(record.productTask == .summarize)
        #expect(record.state == .active)
        #expect(record.startedAt == initialDate)
        #expect(record.heartbeatAt == initialDate)
        #expect(record.expiresAt == Date(timeIntervalSince1970: 1_788_184_845))
        #expect(record.endedAt == nil)
        #expect(record.outcome == nil)
        #expect(fixture.exists(in: .active, id: id))
        #expect(!fixture.exists(in: .recent, id: id))
    }

    // Catches sub-second system clocks producing records that the strict Task 1 codec cannot decode.
    @Test func beginCanonicalizesClockToWholeSeconds() async throws {
        let fractional = Date(timeIntervalSince1970: 1_788_184_800.875)
        let fixture = try ActivityLedgerFixture(now: fractional)
        defer { fixture.remove() }

        let id = try await fixture.ledger.begin(.foundationModels(role: .cli, task: .extract))
        let record = try fixture.record(in: .active, id: id)

        #expect(record.startedAt == initialDate)
        #expect(record.expiresAt == Date(timeIntervalSince1970: 1_788_184_845))
    }

    // Catches needless writes before the 15-second heartbeat floor or failure to renew exactly at the floor.
    @Test func heartbeatHonorsFifteenSecondRewriteFloor() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .mcp, task: .organize))
        let originalInode = try fixture.inode(in: .active, id: id)

        fixture.clock.advance(by: 14)
        try await fixture.ledger.heartbeat(id)
        #expect(try fixture.inode(in: .active, id: id) == originalInode)
        #expect(try fixture.record(in: .active, id: id).heartbeatAt == initialDate)

        fixture.clock.advance(by: 1)
        try await fixture.ledger.heartbeat(id)
        let renewed = try fixture.record(in: .active, id: id)
        #expect(try fixture.inode(in: .active, id: id) != originalInode)
        #expect(renewed.heartbeatAt == Date(timeIntervalSince1970: 1_788_184_815))
        #expect(renewed.expiresAt == Date(timeIntervalSince1970: 1_788_184_860))
    }

    // Catches an end path that leaks detailed error content, leaves active state behind, or uses a retention other than 24 hours.
    @Test(arguments: [
        LocalAIActivityOutcome.success,
        LocalAIActivityOutcome.cancelled,
        LocalAIActivityOutcome.failure
    ])
    func endMovesOnlyGenericOutcomeToRecent(outcome: LocalAIActivityOutcome) async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))
        fixture.clock.advance(by: 30)

        try await fixture.ledger.end(id, outcome: outcome)
        let record = try fixture.record(in: .recent, id: id)

        #expect(!fixture.exists(in: .active, id: id))
        #expect(record.state == .ended)
        #expect(record.endedAt == Date(timeIntervalSince1970: 1_788_184_830))
        #expect(record.expiresAt == Date(timeIntervalSince1970: 1_788_271_230))
        #expect(record.outcome == outcome)
        let object = try #require(JSONSerialization.jsonObject(with: fixture.data(in: .recent, id: id)) as? [String: Any])
        #expect(Set(object.keys) == Set(LocalAIActivityRecord.CodingKeys.allCases.map(\.rawValue)))
    }

    // Catches duplicate calls that rewrite history or an unknown end that fabricates a recent activity.
    @Test func duplicateOperationsAreIdempotentAndUnknownEndCreatesNothing() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .cli, task: .extract))
        try await fixture.ledger.end(id, outcome: .success)
        let endedData = try fixture.data(in: .recent, id: id)
        let endedInode = try fixture.inode(in: .recent, id: id)

        try await fixture.ledger.heartbeat(id)
        try await fixture.ledger.end(id, outcome: .failure)
        try await fixture.ledger.end(UUID(), outcome: .success)

        #expect(try fixture.data(in: .recent, id: id) == endedData)
        #expect(try fixture.inode(in: .recent, id: id) == endedInode)
        #expect(try fixture.allRecordURLs(in: .active).isEmpty)
        #expect(try fixture.allRecordURLs(in: .recent).count == 1)
    }

    // Catches a singleton ledger filename or shared mutable record that lets concurrent producer roles overwrite each other.
    @Test func concurrentRolesReceiveIndependentActivityFiles() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let descriptors: [LocalAIActivityDescriptor] = [
            .foundationModels(role: .studio, task: .summarize),
            .foundationModels(role: .mcp, task: .organize),
            .foundationModels(role: .cli, task: .extract),
            .foundationModels(role: .iosApp, platform: .ios, task: .summarize)
        ]

        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for descriptor in descriptors {
                group.addTask { try await fixture.ledger.begin(descriptor) }
            }
            var values: [UUID] = []
            for try await id in group { values.append(id) }
            return values
        }

        #expect(Set(ids).count == 4)
        let records = try ids.map { try fixture.record(in: .active, id: $0) }
        #expect(Set(records.map(\.producerRole)) == Set([.studio, .mcp, .cli, .iosApp]))
        #expect(try fixture.allRecordURLs(in: .active).count == 4)
    }

    // Catches cross-process cleanup that deletes the complete ended-active record before its atomic move to recent.
    @Test func concurrentCleanupPreservesEndTransitionAcrossLedgerInstances() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let pausingStore = PausingMoveActivityStore(containerURL: fixture.containerURL)
        let endingLedger = LocalAIActivityLedger(store: pausingStore, clock: fixture.clock)
        let cleanupLedger = LocalAIActivityLedger(containerURL: fixture.containerURL, clock: fixture.clock)
        let id = try await endingLedger.begin(.foundationModels(role: .studio, task: .summarize))

        let endTask = Task {
            try await endingLedger.end(id, outcome: .success)
        }
        defer { pausingStore.releaseMove() }
        let reachedMove = await pausingStore.waitUntilMoveRequested()
        #expect(reachedMove)
        guard reachedMove else {
            _ = try? await endTask.value
            return
        }

        let concurrentID = try await cleanupLedger.begin(.foundationModels(role: .mcp, task: .extract))
        pausingStore.releaseMove()
        try await endTask.value

        #expect(fixture.exists(in: .active, id: concurrentID))
        #expect(!fixture.exists(in: .active, id: id))
        let ended = try fixture.record(in: .recent, id: id)
        #expect(ended.state == .ended)
        #expect(ended.outcome == .success)
        #expect(ended.expiresAt == Date(timeIntervalSince1970: 1_788_271_200))
    }

    // Catches inclusive-boundary errors that keep an abandoned active lease valid at its exact 45-second deadline.
    @Test func beginOpportunisticallyRemovesLeaseAtExactExpiry() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let abandonedID = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))
        fixture.clock.advance(by: 45)

        let replacementID = try await fixture.ledger.begin(.foundationModels(role: .mcp, task: .extract))

        #expect(!fixture.exists(in: .active, id: abandonedID))
        #expect(fixture.exists(in: .active, id: replacementID))
    }

    // Catches inclusive-boundary errors that retain ended activity beyond its exact 24-hour deadline.
    @Test func cleanupRemovesRecentRecordAtExactRetentionDeadline() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))
        try await fixture.ledger.end(id, outcome: .success)
        fixture.clock.advance(by: 86_400)

        await fixture.ledger.cleanupExpired()

        #expect(!fixture.exists(in: .recent, id: id))
    }

    // Catches permissive recovery that turns malformed or mismatched bytes into a fresh valid heartbeat.
    @Test func heartbeatDeletesMalformedAndMismatchedActiveRecords() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let store = SecureLocalAIActivityFileStore(containerURL: fixture.containerURL)
        try store.prepareLedgerDirectories()
        let malformedID = UUID()
        try store.atomicallyWrite(Data(#"{"prompt":"private text"}"#.utf8), id: malformedID, to: .active)
        let mismatchedID = UUID()
        let otherID = UUID()
        try store.atomicallyWrite(
            try LocalAIActivityContract.encode(activeRecord(id: otherID, at: initialDate)),
            id: mismatchedID,
            to: .active
        )

        try await fixture.ledger.heartbeat(malformedID)
        try await fixture.ledger.heartbeat(mismatchedID)

        #expect(!fixture.exists(in: .active, id: malformedID))
        #expect(!fixture.exists(in: .active, id: mismatchedID))
    }

    // Catches cleanup that loses the conditional identity when a hostile record crosses the bounded-read limit.
    @Test func cleanupRemovesOversizedActiveAndRecentRecords() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let store = SecureLocalAIActivityFileStore(containerURL: fixture.containerURL)
        try store.prepareLedgerDirectories()
        let activeID = UUID()
        let recentID = UUID()
        let oversized = Data(repeating: 0x41, count: LocalAIActivityContract.maximumRecordBytes + 1)
        for (id, directory) in [(activeID, LocalAILedgerDirectory.active), (recentID, .recent)] {
            let url = fixture.recordURL(in: directory, id: id)
            try oversized.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        await fixture.ledger.cleanupExpired()

        #expect(!fixture.exists(in: .active, id: activeID))
        #expect(!fixture.exists(in: .recent, id: recentID))
    }

    // Catches oversized cleanup that deletes a valid renewal replacing the hostile bytes after its bounded inspection.
    @Test func oversizedCleanupDoesNotDeleteAReplacementLease() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = UUID()
        let secureStore = SecureLocalAIActivityFileStore(containerURL: fixture.containerURL)
        try secureStore.prepareLedgerDirectories()
        let oversized = Data(repeating: 0x41, count: LocalAIActivityContract.maximumRecordBytes + 1)
        let url = fixture.recordURL(in: .active, id: id)
        try oversized.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let renewal = activeRecord(id: id, at: initialDate)
        let store = ReplacingActivityStore(
            containerURL: fixture.containerURL,
            replacementID: id,
            replacement: try LocalAIActivityContract.encode(renewal),
            replacementPhase: .remove
        )
        let ledger = LocalAIActivityLedger(store: store, clock: fixture.clock)

        await ledger.cleanupExpired()

        #expect(try fixture.record(in: .active, id: id) == renewal)
        #expect(!fixture.exists(in: .recent, id: id))
    }

    // Catches a failed deletion path that resurrects an expired record by writing it with a new lease.
    @Test func failedExpiredCleanupNeverRewritesTheRecordAsValid() async throws {
        let id = UUID()
        let expired = activeRecord(id: id, at: initialDate)
        let store = RemoveFailingActivityStore(records: [id: try LocalAIActivityContract.encode(expired)])
        let clock = TestLocalAIActivityClock(now: Date(timeIntervalSince1970: 1_788_184_845))
        let ledger = LocalAIActivityLedger(store: store, clock: clock)

        try await ledger.heartbeat(id)

        #expect(store.writeCount == 0)
        #expect(store.removeAttempts == [id])
    }

    // Catches cleanup that unlinks a valid renewal which replaced the expired bytes after validation.
    @Test func expiredCleanupDoesNotDeleteAReplacementLease() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))
        fixture.clock.advance(by: 45)
        let renewal = activeRecord(id: id, at: Date(timeIntervalSince1970: 1_788_184_845))
        let store = ReplacingActivityStore(
            containerURL: fixture.containerURL,
            replacementID: id,
            replacement: try LocalAIActivityContract.encode(renewal),
            replacementPhase: .remove
        )
        let renewingLedger = LocalAIActivityLedger(store: store, clock: fixture.clock)

        try await renewingLedger.heartbeat(id)

        #expect(try fixture.record(in: .active, id: id) == renewal)
        #expect(!fixture.exists(in: .recent, id: id))
    }

    // Catches ended-active recovery that moves a valid renewal which replaced the ended bytes after validation.
    @Test func endedActiveRecoveryDoesNotMoveAReplacementLease() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = UUID()
        let store = SecureLocalAIActivityFileStore(containerURL: fixture.containerURL)
        try store.prepareLedgerDirectories()
        let ended = LocalAIActivityRecord(
            schemaVersion: 1,
            activityID: id,
            producerID: "com.rayconsulting.localocr",
            producerRole: .studio,
            platform: .macos,
            runtimeFamily: .foundationModels,
            runtimeIdentifier: "SystemLanguageModel.default",
            route: .onDevice,
            operation: .generation,
            productTask: .summarize,
            state: .ended,
            startedAt: initialDate,
            heartbeatAt: initialDate,
            expiresAt: initialDate.addingTimeInterval(86_400),
            endedAt: initialDate,
            outcome: .success,
            evidence: .participatingAppReported
        )
        try store.atomicallyWrite(try LocalAIActivityContract.encode(ended), id: id, to: .active)
        let renewal = activeRecord(id: id, at: initialDate.addingTimeInterval(1))
        let replacingStore = ReplacingActivityStore(
            containerURL: fixture.containerURL,
            replacementID: id,
            replacement: try LocalAIActivityContract.encode(renewal),
            replacementPhase: .move
        )
        let ledger = LocalAIActivityLedger(store: replacingStore, clock: fixture.clock)

        await ledger.cleanupExpired()

        #expect(try fixture.record(in: .active, id: id) == renewal)
        #expect(!fixture.exists(in: .recent, id: id))
    }

    // Catches cleanup loops that abort after one hostile entry and leave unrelated expired activity visible.
    @Test func cleanupContinuesAfterAnIndividualRemovalFailure() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let encoded = try LocalAIActivityContract.encode(activeRecord(id: firstID, at: initialDate))
        let secondEncoded = try LocalAIActivityContract.encode(activeRecord(id: secondID, at: initialDate))
        let store = SelectiveRemoveFailingActivityStore(
            records: [firstID: encoded, secondID: secondEncoded],
            failingID: firstID
        )
        let clock = TestLocalAIActivityClock(now: Date(timeIntervalSince1970: 1_788_184_845))
        let ledger = LocalAIActivityLedger(store: store, clock: clock)

        await ledger.cleanupExpired()

        #expect(Set(store.removeAttempts) == Set([firstID, secondID]))
        #expect(store.remainingIDs == [firstID])
    }

    // Catches reporting code that persists a caller-supplied prompt, path, URL, or unregistered identifier.
    @Test func unregisteredDescriptorCannotCreateARecord() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let unsafe = LocalAIActivityDescriptor(
            producerID: "../../user/prompt",
            producerRole: .studio,
            platform: .macos,
            runtimeFamily: .foundationModels,
            runtimeIdentifier: "https://example.com/private-model",
            route: .onDevice,
            operation: .generation,
            productTask: .summarize
        )

        await #expect(throws: LocalAIActivityContractError.self) {
            _ = try await fixture.ledger.begin(unsafe)
        }
        #expect(try fixture.allRecordURLs(in: .active).isEmpty)
    }

    // Catches creation paths that rely on process umask instead of enforcing 0700 directories and 0600 records.
    @Test func ledgerCreatesOnlyPrivateDirectoryAndFileModes() async throws {
        let fixture = try ActivityLedgerFixture(now: initialDate)
        defer { fixture.remove() }
        let id = try await fixture.ledger.begin(.foundationModels(role: .studio, task: .summarize))

        for component in ["LocalAIActivity", "LocalAIActivity/v1", "LocalAIActivity/v1/active", "LocalAIActivity/v1/recent"] {
            #expect(try fixture.mode(at: fixture.containerURL.appending(path: component, directoryHint: .isDirectory)) == 0o700)
        }
        #expect(try fixture.mode(at: fixture.recordURL(in: .active, id: id)) == 0o600)
    }
}

private struct ActivityLedgerFixture {
    let containerURL: URL
    let clock: TestLocalAIActivityClock
    let ledger: LocalAIActivityLedger

    init(now: Date) throws {
        containerURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: false)
        clock = TestLocalAIActivityClock(now: now)
        ledger = LocalAIActivityLedger(containerURL: containerURL, clock: clock)
    }

    func remove() {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func recordURL(in directory: LocalAILedgerDirectory, id: UUID) -> URL {
        containerURL
            .appending(path: "LocalAIActivity/v1/\(directory.rawValue)", directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString.lowercased()).json", directoryHint: .notDirectory)
    }

    func data(in directory: LocalAILedgerDirectory, id: UUID) throws -> Data {
        try Data(contentsOf: recordURL(in: directory, id: id))
    }

    func record(in directory: LocalAILedgerDirectory, id: UUID) throws -> LocalAIActivityRecord {
        try LocalAIActivityContract.decode(data(in: directory, id: id))
    }

    func exists(in directory: LocalAILedgerDirectory, id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(in: directory, id: id).path)
    }

    func allRecordURLs(in directory: LocalAILedgerDirectory) throws -> [URL] {
        let url = containerURL.appending(
            path: "LocalAIActivity/v1/\(directory.rawValue)",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    func inode(in directory: LocalAILedgerDirectory, id: UUID) throws -> ino_t {
        var metadata = stat()
        guard lstat(recordURL(in: directory, id: id).path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return metadata.st_ino
    }

    func mode(at url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & 0o777
    }
}

private final class TestLocalAIActivityClock: LocalAIActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(for duration: Duration) async throws {}

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private func activeRecord(id: UUID, at date: Date) -> LocalAIActivityRecord {
    LocalAIActivityRecord(
        schemaVersion: 1,
        activityID: id,
        producerID: "com.rayconsulting.localocr",
        producerRole: .studio,
        platform: .macos,
        runtimeFamily: .foundationModels,
        runtimeIdentifier: "SystemLanguageModel.default",
        route: .onDevice,
        operation: .generation,
        productTask: .summarize,
        state: .active,
        startedAt: date,
        heartbeatAt: date,
        expiresAt: date.addingTimeInterval(45),
        endedAt: nil,
        outcome: nil,
        evidence: .participatingAppReported
    )
}

private func testSnapshot(_ data: Data) -> LocalAIActivityRecordSnapshot {
    LocalAIActivityRecordSnapshot(
        data: data,
        version: LocalAIActivityRecordVersion(
            device: 0,
            inode: 0,
            generation: 0,
            byteCount: Int64(data.count),
            modifiedSeconds: 0,
            modifiedNanoseconds: 0,
            changedSeconds: 0,
            changedNanoseconds: 0,
            contentEvidence: data
        )
    )
}

private final class RemoveFailingActivityStore: LocalAIActivityFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data]
    private var writes = 0
    private var removals: [UUID] = []

    init(records: [UUID: Data]) {
        self.records = records
    }

    var writeCount: Int { lock.withLock { writes } }
    var removeAttempts: [UUID] { lock.withLock { removals } }

    func prepareLedgerDirectories() throws {}
    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult? {
        lock.withLock { records[id].map { .record(testSnapshot($0)) } }
    }
    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws {
        lock.withLock { writes += 1 }
    }
    func replaceRecord(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> LocalAIActivityRecordSnapshot? {
        lock.withLock { writes += 1 }
        return testSnapshot(data)
    }
    func atomicallyMove(id: UUID, from: LocalAILedgerDirectory, to: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool { true }
    func remove(id: UUID, from directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool {
        lock.withLock { removals.append(id) }
        throw POSIXError(.EACCES)
    }
    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID] {
        lock.withLock { Array(records.keys) }
    }
}

private final class SelectiveRemoveFailingActivityStore: LocalAIActivityFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data]
    private let failingID: UUID
    private var removals: [UUID] = []

    init(records: [UUID: Data], failingID: UUID) {
        self.records = records
        self.failingID = failingID
    }

    var removeAttempts: [UUID] { lock.withLock { removals } }
    var remainingIDs: Set<UUID> { lock.withLock { Set(records.keys) } }

    func prepareLedgerDirectories() throws {}
    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult? {
        lock.withLock { records[id].map { .record(testSnapshot($0)) } }
    }
    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws {}
    func replaceRecord(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> LocalAIActivityRecordSnapshot? {
        lock.withLock { records[id] = data }
        return testSnapshot(data)
    }
    func atomicallyMove(id: UUID, from: LocalAILedgerDirectory, to: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool { true }
    func remove(id: UUID, from directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool {
        try lock.withLock {
            removals.append(id)
            if id == failingID { throw POSIXError(.EACCES) }
            records.removeValue(forKey: id)
            return true
        }
    }
    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID] {
        lock.withLock { Array(records.keys) }
    }
}

private final class ReplacingActivityStore: LocalAIActivityFileStoring, @unchecked Sendable {
    enum ReplacementPhase {
        case remove
        case move
    }

    private let underlying: SecureLocalAIActivityFileStore
    private let replacementID: UUID
    private let replacement: Data
    private let replacementPhase: ReplacementPhase
    private var hasReplaced = false

    init(
        containerURL: URL,
        replacementID: UUID,
        replacement: Data,
        replacementPhase: ReplacementPhase
    ) {
        underlying = SecureLocalAIActivityFileStore(containerURL: containerURL)
        self.replacementID = replacementID
        self.replacement = replacement
        self.replacementPhase = replacementPhase
    }

    func prepareLedgerDirectories() throws {
        try underlying.prepareLedgerDirectories()
    }

    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult? {
        try underlying.readRecord(id: id, from: directory)
    }

    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws {
        try underlying.atomicallyWrite(data, id: id, to: directory)
    }

    func replaceRecord(
        _ data: Data,
        id: UUID,
        to directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> LocalAIActivityRecordSnapshot? {
        try underlying.replaceRecord(data, id: id, to: directory, expectedVersion: expectedVersion)
    }

    func atomicallyMove(
        id: UUID,
        from sourceDirectory: LocalAILedgerDirectory,
        to destinationDirectory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool {
        if replacementPhase == .move, id == replacementID, !hasReplaced {
            hasReplaced = true
            try underlying.atomicallyWrite(replacement, id: id, to: sourceDirectory)
        }
        return try underlying.atomicallyMove(
            id: id,
            from: sourceDirectory,
            to: destinationDirectory,
            expectedVersion: expectedVersion
        )
    }

    func remove(id: UUID, from directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool {
        if replacementPhase == .remove, id == replacementID, !hasReplaced {
            hasReplaced = true
            try underlying.atomicallyWrite(replacement, id: id, to: directory)
        }
        return try underlying.remove(id: id, from: directory, expectedVersion: expectedVersion)
    }

    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID] {
        try underlying.recordIDs(in: directory)
    }
}

private final class PausingMoveActivityStore: LocalAIActivityFileStoring, @unchecked Sendable {
    private let underlying: SecureLocalAIActivityFileStore
    private let moveRequested = DispatchSemaphore(value: 0)
    private let moveAllowed = DispatchSemaphore(value: 0)

    init(containerURL: URL) {
        underlying = SecureLocalAIActivityFileStore(containerURL: containerURL)
    }

    func waitUntilMoveRequested() async -> Bool {
        await Task.detached {
            self.waitSynchronouslyUntilMoveRequested()
        }.value
    }

    private func waitSynchronouslyUntilMoveRequested() -> Bool {
        moveRequested.wait(timeout: .now() + 5) == .success
    }

    func releaseMove() {
        moveAllowed.signal()
    }

    func prepareLedgerDirectories() throws {
        try underlying.prepareLedgerDirectories()
    }

    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult? {
        try underlying.readRecord(id: id, from: directory)
    }

    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws {
        try underlying.atomicallyWrite(data, id: id, to: directory)
    }

    func replaceRecord(
        _ data: Data,
        id: UUID,
        to directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> LocalAIActivityRecordSnapshot? {
        try underlying.replaceRecord(data, id: id, to: directory, expectedVersion: expectedVersion)
    }

    func atomicallyMove(
        id: UUID,
        from sourceDirectory: LocalAILedgerDirectory,
        to destinationDirectory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool {
        moveRequested.signal()
        moveAllowed.wait()
        return try underlying.atomicallyMove(
            id: id,
            from: sourceDirectory,
            to: destinationDirectory,
            expectedVersion: expectedVersion
        )
    }

    func remove(id: UUID, from directory: LocalAILedgerDirectory, expectedVersion: LocalAIActivityRecordVersion) throws -> Bool {
        try underlying.remove(id: id, from: directory, expectedVersion: expectedVersion)
    }

    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID] {
        try underlying.recordIDs(in: directory)
    }
}

import Foundation

public protocol LocalAIActivityLedgerWriting: Sendable {
    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID
    func heartbeat(_ activityID: UUID) async throws
    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws
    func cleanupExpired() async
}

public protocol LocalAIActivityClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemLocalAIActivityClock: LocalAIActivityClock, Sendable {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public actor LocalAIActivityLedger: LocalAIActivityLedgerWriting {
    static let heartbeatInterval: TimeInterval = 15
    static let activeLease: TimeInterval = 45
    static let recentRetention: TimeInterval = 86_400

    private let store: any LocalAIActivityFileStoring
    private let clock: any LocalAIActivityClock
    private var isPrepared = false

    public init(
        containerURL: URL,
        clock: any LocalAIActivityClock = SystemLocalAIActivityClock()
    ) {
        store = SecureLocalAIActivityFileStore(containerURL: containerURL)
        self.clock = clock
    }

    init(store: any LocalAIActivityFileStoring, clock: any LocalAIActivityClock) {
        self.store = store
        self.clock = clock
    }

    public func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        try prepareIfNeeded()
        cleanupExpiredRecords()
        let now = canonicalNow()

        for _ in 0..<32 {
            let id = UUID()
            guard try store.readRecord(id: id, from: .active) == nil,
                  try store.readRecord(id: id, from: .recent) == nil
            else {
                continue
            }
            let record = LocalAIActivityRecord(
                schemaVersion: LocalAIActivityContract.schemaVersion,
                activityID: id,
                producerID: descriptor.producerID,
                producerRole: descriptor.producerRole,
                platform: descriptor.platform,
                runtimeFamily: descriptor.runtimeFamily,
                runtimeIdentifier: descriptor.runtimeIdentifier,
                route: descriptor.route,
                operation: descriptor.operation,
                productTask: descriptor.productTask,
                state: .active,
                startedAt: now,
                heartbeatAt: now,
                expiresAt: now.addingTimeInterval(Self.activeLease),
                endedAt: nil,
                outcome: nil,
                evidence: .participatingAppReported
            )
            try store.atomicallyWrite(try LocalAIActivityContract.encode(record), id: id, to: .active)
            return id
        }
        throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
    }

    public func heartbeat(_ activityID: UUID) async throws {
        try prepareIfNeeded()
        guard let active = try validatedActiveRecord(id: activityID) else { return }
        let record = active.record
        let now = canonicalNow()
        guard now < record.expiresAt else {
            _ = try? store.remove(id: activityID, from: .active, expectedVersion: active.version)
            return
        }
        guard now.timeIntervalSince(record.heartbeatAt) >= Self.heartbeatInterval else { return }

        let renewed = LocalAIActivityRecord(
            schemaVersion: record.schemaVersion,
            activityID: record.activityID,
            producerID: record.producerID,
            producerRole: record.producerRole,
            platform: record.platform,
            runtimeFamily: record.runtimeFamily,
            runtimeIdentifier: record.runtimeIdentifier,
            route: record.route,
            operation: record.operation,
            productTask: record.productTask,
            state: .active,
            startedAt: record.startedAt,
            heartbeatAt: now,
            expiresAt: now.addingTimeInterval(Self.activeLease),
            endedAt: nil,
            outcome: nil,
            evidence: record.evidence
        )
        _ = try store.replaceRecord(
            try LocalAIActivityContract.encode(renewed),
            id: activityID,
            to: .active,
            expectedVersion: active.version
        )
    }

    public func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        try prepareIfNeeded()
        guard let active = try validatedActiveRecord(id: activityID) else { return }
        let record = active.record
        let now = canonicalNow()
        guard now < record.expiresAt else {
            _ = try? store.remove(id: activityID, from: .active, expectedVersion: active.version)
            return
        }

        let ended = LocalAIActivityRecord(
            schemaVersion: record.schemaVersion,
            activityID: record.activityID,
            producerID: record.producerID,
            producerRole: record.producerRole,
            platform: record.platform,
            runtimeFamily: record.runtimeFamily,
            runtimeIdentifier: record.runtimeIdentifier,
            route: record.route,
            operation: record.operation,
            productTask: record.productTask,
            state: .ended,
            startedAt: record.startedAt,
            heartbeatAt: record.heartbeatAt,
            expiresAt: now.addingTimeInterval(Self.recentRetention),
            endedAt: now,
            outcome: outcome,
            evidence: record.evidence
        )
        guard let endedSnapshot = try store.replaceRecord(
            try LocalAIActivityContract.encode(ended),
            id: activityID,
            to: .active,
            expectedVersion: active.version
        ) else {
            return
        }
        _ = try store.atomicallyMove(
            id: activityID,
            from: .active,
            to: .recent,
            expectedVersion: endedSnapshot.version
        )
    }

    public func cleanupExpired() async {
        do {
            try prepareIfNeeded()
        } catch {
            return
        }
        cleanupExpiredRecords()
    }

    private func prepareIfNeeded() throws {
        guard !isPrepared else { return }
        try store.prepareLedgerDirectories()
        isPrepared = true
    }

    private func validatedActiveRecord(id: UUID) throws -> (record: LocalAIActivityRecord, version: LocalAIActivityRecordVersion)? {
        let snapshot: LocalAIActivityRecordSnapshot
        do {
            guard let stored = try store.readRecord(id: id, from: .active) else { return nil }
            switch stored {
            case let .record(record):
                snapshot = record
            case let .oversized(version):
                _ = try? store.remove(id: id, from: .active, expectedVersion: version)
                return nil
            }
        } catch let error as SecureLocalAIActivityFileStoreError {
            switch error {
            case .oversizedRecord, .insecureFilesystemState:
                return nil
            case .invalidContainerPath, .missingLedgerDirectory, .backupExclusionUnavailable,
                 .filesystemOperationFailed:
                throw error
            }
        }

        do {
            let record = try LocalAIActivityContract.decode(snapshot.data)
            guard record.activityID == id, record.state == .active else {
                _ = try? store.remove(id: id, from: .active, expectedVersion: snapshot.version)
                return nil
            }
            return (record, snapshot.version)
        } catch {
            _ = try? store.remove(id: id, from: .active, expectedVersion: snapshot.version)
            return nil
        }
    }

    private func cleanupExpiredRecords() {
        let now = canonicalNow()
        for directory in LocalAILedgerDirectory.allCases {
            let ids: [UUID]
            do {
                ids = try store.recordIDs(in: directory)
            } catch {
                continue
            }
            for id in ids {
                do {
                    guard let stored = try store.readRecord(id: id, from: directory) else { continue }
                    guard case let .record(snapshot) = stored else {
                        if case let .oversized(version) = stored {
                            _ = try? store.remove(id: id, from: directory, expectedVersion: version)
                        }
                        continue
                    }
                    let record: LocalAIActivityRecord
                    do {
                        record = try LocalAIActivityContract.decode(snapshot.data)
                    } catch {
                        _ = try? store.remove(id: id, from: directory, expectedVersion: snapshot.version)
                        continue
                    }
                    if directory == .active,
                       record.activityID == id,
                       record.state == .ended,
                       now < record.expiresAt
                    {
                        _ = try? store.atomicallyMove(
                            id: id,
                            from: .active,
                            to: .recent,
                            expectedVersion: snapshot.version
                        )
                        continue
                    }
                    let expectedState: LocalAIActivityState = directory == .active ? .active : .ended
                    guard record.activityID == id,
                          record.state == expectedState,
                          now < record.expiresAt
                    else {
                        _ = try store.remove(id: id, from: directory, expectedVersion: snapshot.version)
                        continue
                    }
                } catch { continue }
            }
        }
    }

    private func canonicalNow() -> Date {
        Date(timeIntervalSince1970: floor(clock.now().timeIntervalSince1970))
    }
}

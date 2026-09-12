import Darwin
import Foundation

enum LocalAILedgerDirectory: String, CaseIterable, Sendable {
    case active
    case recent
}

struct LocalAIActivityRecordVersion: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let contentEvidence: Data
}

private struct LocalAIActivityFilesystemIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

struct LocalAIActivityRecordSnapshot: Sendable {
    let data: Data
    let version: LocalAIActivityRecordVersion
}

enum LocalAIActivityRecordReadResult: Sendable {
    case record(LocalAIActivityRecordSnapshot)
    case oversized(LocalAIActivityRecordVersion)
}

protocol LocalAIActivityFileStoring: Sendable {
    func prepareLedgerDirectories() throws
    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult?
    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws
    func replaceRecord(
        _ data: Data,
        id: UUID,
        to directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> LocalAIActivityRecordSnapshot?
    func atomicallyMove(
        id: UUID,
        from: LocalAILedgerDirectory,
        to: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool
    func remove(
        id: UUID,
        from directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool
    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID]
}

enum SecureLocalAIActivityFileStoreError: Error, Sendable, Equatable {
    case invalidContainerPath
    case missingLedgerDirectory
    case insecureFilesystemState
    case oversizedRecord
    case backupExclusionUnavailable
    case filesystemOperationFailed(Int32)
}

struct SecureLocalAIActivityFileStoreHooks: Sendable {
    typealias BackupExclusion = @Sendable (URL) throws -> Void
    typealias DescriptorSynchronization = @Sendable (Int32) -> Int32

    let applyAndVerifyBackupExclusion: BackupExclusion
    let synchronizeDescriptor: DescriptorSynchronization

    init(
        applyAndVerifyBackupExclusion: @escaping BackupExclusion = { url in
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
            let verified = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            guard verified.isExcludedFromBackup == true else {
                throw SecureLocalAIActivityFileStoreError.backupExclusionUnavailable
            }
        },
        synchronizeDescriptor: @escaping DescriptorSynchronization = { descriptor in
            while fsync(descriptor) != 0 {
                if errno != EINTR { return errno }
            }
            return 0
        }
    ) {
        self.applyAndVerifyBackupExclusion = applyAndVerifyBackupExclusion
        self.synchronizeDescriptor = synchronizeDescriptor
    }
}

struct SecureLocalAIActivityFileStore: LocalAIActivityFileStoring, Sendable {
    private static let ledgerRootName = "LocalAIActivity"
    private static let versionName = "v1"
    private static let mutationLockName = ".mutation.lock"

    private enum BoundedRecord {
        case record(Data)
        case oversized(Data)

        var evidence: Data {
            switch self {
            case let .record(data), let .oversized(data): data
            }
        }
    }

    private let containerURL: URL
    private let expectedOwnerID: uid_t
    private let hooks: SecureLocalAIActivityFileStoreHooks

    init(
        containerURL: URL,
        expectedOwnerID: uid_t = geteuid(),
        hooks: SecureLocalAIActivityFileStoreHooks = SecureLocalAIActivityFileStoreHooks()
    ) {
        self.containerURL = containerURL
        self.expectedOwnerID = expectedOwnerID
        self.hooks = hooks
    }

    func prepareLedgerDirectories() throws {
        let container = try openContainerDirectory()
        defer { Darwin.close(container) }

        let root = try openOrCreatePrivateDirectory(named: Self.ledgerRootName, beneath: container)
        defer { Darwin.close(root) }
        let rootIdentity = try filesystemIdentity(ofDescriptor: root)

        let version = try openOrCreatePrivateDirectory(named: Self.versionName, beneath: root)
        defer { Darwin.close(version) }
        for directory in LocalAILedgerDirectory.allCases {
            let descriptor = try openOrCreatePrivateDirectory(named: directory.rawValue, beneath: version)
            Darwin.close(descriptor)
        }

        do {
            try hooks.applyAndVerifyBackupExclusion(
                containerURL.appending(path: Self.ledgerRootName, directoryHint: .isDirectory)
            )
        } catch let error as SecureLocalAIActivityFileStoreError {
            throw error
        } catch {
            throw SecureLocalAIActivityFileStoreError.backupExclusionUnavailable
        }

        guard try filesystemIdentity(ofEntry: Self.ledgerRootName, beneath: container) == rootIdentity,
              try filesystemIdentity(ofDescriptor: root) == rootIdentity
        else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        try requirePrivateDirectory(root)
    }

    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> LocalAIActivityRecordReadResult? {
        try withLedgerDirectory(directory) { directoryDescriptor in
            try inspectRecord(named: recordName(id), beneath: directoryDescriptor)
        }
    }

    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws {
        guard data.count <= LocalAIActivityContract.maximumRecordBytes else {
            throw SecureLocalAIActivityFileStoreError.oversizedRecord
        }

        try withMutationLock {
            try withLedgerDirectory(directory) { directoryDescriptor in
                _ = try writeRecord(data, id: id, beneath: directoryDescriptor, expectedVersion: nil)
            }
        }
    }

    func replaceRecord(
        _ data: Data,
        id: UUID,
        to directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> LocalAIActivityRecordSnapshot? {
        guard data.count <= LocalAIActivityContract.maximumRecordBytes else {
            throw SecureLocalAIActivityFileStoreError.oversizedRecord
        }

        return try withMutationLock {
            try withLedgerDirectory(directory) { directoryDescriptor in
                try writeRecord(
                    data,
                    id: id,
                    beneath: directoryDescriptor,
                    expectedVersion: expectedVersion
                )
            }
        }
    }

    private func writeRecord(
        _ data: Data,
        id: UUID,
        beneath directoryDescriptor: Int32,
        expectedVersion: LocalAIActivityRecordVersion?
    ) throws -> LocalAIActivityRecordSnapshot? {
        let finalName = recordName(id)
        if let existing = try entryMetadata(named: finalName, beneath: directoryDescriptor) {
            try validateRecordMetadata(existing)
            if let expectedVersion,
               try currentRecordVersion(named: finalName, beneath: directoryDescriptor) != expectedVersion {
                return nil
            }
        } else if expectedVersion != nil {
            return nil
        }

        let temporary = try createTemporaryFile(for: id, beneath: directoryDescriptor)
        var temporaryExists = true
        defer {
            Darwin.close(temporary.descriptor)
            if temporaryExists {
                _ = temporary.name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        try writeAll(data, to: temporary.descriptor)
        try synchronize(temporary.descriptor)
        guard try filesystemIdentity(ofEntry: temporary.name, beneath: directoryDescriptor) == temporary.identity else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        if let existing = try entryMetadata(named: finalName, beneath: directoryDescriptor) {
            try validateRecordMetadata(existing)
            if let expectedVersion,
               try currentRecordVersion(named: finalName, beneath: directoryDescriptor) != expectedVersion {
                return nil
            }
        } else if expectedVersion != nil {
            return nil
        }

        let renameStatus = temporary.name.withCString { source in
            finalName.withCString { destination in
                renameat(directoryDescriptor, source, directoryDescriptor, destination)
            }
        }
        guard renameStatus == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        temporaryExists = false

        guard let published = try entryMetadata(named: finalName, beneath: directoryDescriptor) else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        try validateRecordMetadata(published)
        guard filesystemIdentity(of: published) == temporary.identity else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        try synchronize(directoryDescriptor)
        return LocalAIActivityRecordSnapshot(
            data: data,
            version: version(of: published, contentEvidence: data)
        )
    }

    private func inspectRecord(
        named name: String,
        beneath directoryDescriptor: Int32
    ) throws -> LocalAIActivityRecordReadResult? {
        guard let beforeOpen = try entryMetadata(named: name, beneath: directoryDescriptor) else {
            return nil
        }
        try validateRecordMetadata(beforeOpen)

        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        try validateRecordMetadata(openedMetadata)
        guard sameFilesystemIdentity(openedMetadata, beforeOpen) else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }

        let bounded = try readBounded(from: descriptor)
        guard let afterRead = try entryMetadata(named: name, beneath: directoryDescriptor) else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        try validateRecordMetadata(afterRead)
        guard sameMetadataGeneration(afterRead, openedMetadata) else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        let version = version(of: openedMetadata, contentEvidence: bounded.evidence)
        switch bounded {
        case let .record(data):
            return .record(LocalAIActivityRecordSnapshot(data: data, version: version))
        case .oversized:
            return .oversized(version)
        }
    }

    func atomicallyMove(
        id: UUID,
        from sourceDirectory: LocalAILedgerDirectory,
        to destinationDirectory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool {
        try withMutationLock {
            let container = try openContainerDirectory()
            defer { Darwin.close(container) }
            let root = try openPrivateDirectory(named: Self.ledgerRootName, beneath: container)
            defer { Darwin.close(root) }
            let versionDirectory = try openPrivateDirectory(named: Self.versionName, beneath: root)
            defer { Darwin.close(versionDirectory) }
            let source = try openPrivateDirectory(named: sourceDirectory.rawValue, beneath: versionDirectory)
            defer { Darwin.close(source) }
            let destination = try openPrivateDirectory(named: destinationDirectory.rawValue, beneath: versionDirectory)
            defer { Darwin.close(destination) }

            let name = recordName(id)
            guard let sourceResult = try inspectRecord(named: name, beneath: source),
                  version(of: sourceResult) == expectedVersion,
                  try entryMetadata(named: name, beneath: destination) == nil
            else { return false }

            let renameStatus = name.withCString { component in
                renameat(source, component, destination, component)
            }
            guard renameStatus == 0 else {
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
            guard let moved = try entryMetadata(named: name, beneath: destination) else {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            try validateRecordMetadata(moved)
            guard sameFilesystemIdentity(moved, expectedVersion) else {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            try synchronize(source)
            try synchronize(destination)
            return true
        }
    }

    func remove(
        id: UUID,
        from directory: LocalAILedgerDirectory,
        expectedVersion: LocalAIActivityRecordVersion
    ) throws -> Bool {
        try withMutationLock {
            try withLedgerDirectory(directory) { directoryDescriptor in
                let name = recordName(id)
                guard let result = try inspectRecord(named: name, beneath: directoryDescriptor),
                      version(of: result) == expectedVersion
                else { return false }
                let status = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                guard status == 0 else {
                    if errno == ENOENT { return false }
                    throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
                }
                try synchronize(directoryDescriptor)
                return true
            }
        }
    }

    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID] {
        try withLedgerDirectory(directory) { directoryDescriptor in
            let duplicate = dup(directoryDescriptor)
            guard duplicate >= 0 else {
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
            guard let stream = fdopendir(duplicate) else {
                let code = errno
                Darwin.close(duplicate)
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(code)
            }
            defer { closedir(stream) }

            var ids: [UUID] = []
            errno = 0
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                guard name.hasSuffix(".json") else { continue }
                let rawID = String(name.dropLast(5))
                guard let id = UUID(uuidString: rawID),
                      name == recordName(id)
                else {
                    continue
                }
                ids.append(id)
            }
            guard errno == 0 else {
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
            return ids.sorted { $0.uuidString < $1.uuidString }
        }
    }

    private func withLedgerDirectory<Result>(
        _ directory: LocalAILedgerDirectory,
        body: (Int32) throws -> Result
    ) throws -> Result {
        let container = try openContainerDirectory()
        defer { Darwin.close(container) }
        let root = try openPrivateDirectory(named: Self.ledgerRootName, beneath: container)
        defer { Darwin.close(root) }
        let version = try openPrivateDirectory(named: Self.versionName, beneath: root)
        defer { Darwin.close(version) }
        let ledgerDirectory = try openPrivateDirectory(named: directory.rawValue, beneath: version)
        defer { Darwin.close(ledgerDirectory) }
        return try body(ledgerDirectory)
    }

    private func withMutationLock<Result>(body: () throws -> Result) throws -> Result {
        let container = try openContainerDirectory()
        defer { Darwin.close(container) }
        let root = try openPrivateDirectory(named: Self.ledgerRootName, beneath: container)
        defer { Darwin.close(root) }
        let version = try openPrivateDirectory(named: Self.versionName, beneath: root)
        defer { Darwin.close(version) }

        let descriptor = Self.mutationLockName.withCString {
            openat(version, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        try validateRecordMetadata(metadata)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func openContainerDirectory() throws -> Int32 {
        guard containerURL.isFileURL,
              containerURL.path.hasPrefix("/"),
              containerURL.pathComponents.count > 1,
              containerURL.pathComponents.allSatisfy({ $0 == "/" || isSafeComponent($0) }),
              isSafeComponent(containerURL.lastPathComponent)
        else {
            throw SecureLocalAIActivityFileStoreError.invalidContainerPath
        }

        let parentDescriptor = Darwin.open(
            containerURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        defer { Darwin.close(parentDescriptor) }

        guard let beforeOpen = try entryMetadata(
            named: containerURL.lastPathComponent,
            beneath: parentDescriptor
        ), fileType(beforeOpen) == S_IFDIR else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        let descriptor = containerURL.lastPathComponent.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  fileType(metadata) == S_IFDIR,
                  metadata.st_uid == expectedOwnerID,
                  sameFilesystemIdentity(metadata, beforeOpen)
            else {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openOrCreatePrivateDirectory(named name: String, beneath parent: Int32) throws -> Int32 {
        guard isSafeComponent(name) else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        var created = false
        if try entryMetadata(named: name, beneath: parent) == nil {
            let status = name.withCString { mkdirat(parent, $0, 0o700) }
            if status == 0 {
                created = true
            } else if errno != EEXIST {
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
        }

        let descriptor = try openPrivateDirectory(named: name, beneath: parent, requirePrivateMode: !created)
        do {
            if created {
                guard fchmod(descriptor, 0o700) == 0 else {
                    throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
                }
                try requirePrivateDirectory(descriptor)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openPrivateDirectory(
        named name: String,
        beneath parent: Int32,
        requirePrivateMode: Bool = true
    ) throws -> Int32 {
        guard isSafeComponent(name),
              let beforeOpen = try entryMetadata(named: name, beneath: parent),
              fileType(beforeOpen) == S_IFDIR
        else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameFilesystemIdentity(opened, beforeOpen)
            else {
                throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
            }
            if requirePrivateMode { try requirePrivateDirectory(descriptor) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              fileType(metadata) == S_IFDIR,
              metadata.st_uid == expectedOwnerID,
              metadata.st_mode & 0o7777 == 0o700
        else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
    }

    private func createTemporaryFile(
        for id: UUID,
        beneath directoryDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String, identity: LocalAIActivityFilesystemIdentity) {
        for _ in 0..<32 {
            let name = ".\(id.uuidString.lowercased()).\(UUID().uuidString.lowercased()).tmp"
            let descriptor = name.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
            do {
                guard fchmod(descriptor, 0o600) == 0 else {
                    throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
                }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else {
                    throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
                }
                try validateRecordMetadata(metadata)
                return (descriptor, name, filesystemIdentity(of: metadata))
            } catch {
                Darwin.close(descriptor)
                _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                throw error
            }
        }
        throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
    }

    private func validateRecordMetadata(_ metadata: stat) throws {
        guard fileType(metadata) == S_IFREG,
              metadata.st_uid == expectedOwnerID,
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600
        else {
            throw SecureLocalAIActivityFileStoreError.insecureFilesystemState
        }
    }

    private func entryMetadata(named name: String, beneath parent: Int32) throws -> stat? {
        var metadata = stat()
        let status = name.withCString { fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
        if status == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
    }

    private func currentRecordVersion(
        named name: String,
        beneath parent: Int32
    ) throws -> LocalAIActivityRecordVersion? {
        try inspectRecord(named: name, beneath: parent).map(version(of:))
    }

    private func filesystemIdentity(ofEntry name: String, beneath parent: Int32) throws -> LocalAIActivityFilesystemIdentity? {
        try entryMetadata(named: name, beneath: parent).map(filesystemIdentity(of:))
    }

    private func filesystemIdentity(ofDescriptor descriptor: Int32) throws -> LocalAIActivityFilesystemIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
        }
        return filesystemIdentity(of: metadata)
    }

    private func filesystemIdentity(of metadata: stat) -> LocalAIActivityFilesystemIdentity {
        LocalAIActivityFilesystemIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func sameFilesystemIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        filesystemIdentity(of: lhs) == filesystemIdentity(of: rhs)
    }

    private func sameFilesystemIdentity(_ metadata: stat, _ version: LocalAIActivityRecordVersion) -> Bool {
        let identity = filesystemIdentity(of: metadata)
        return identity.device == version.device && identity.inode == version.inode
    }

    private func sameMetadataGeneration(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFilesystemIdentity(lhs, rhs) &&
            lhs.st_gen == rhs.st_gen &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func version(of metadata: stat, contentEvidence: Data) -> LocalAIActivityRecordVersion {
        let identity = filesystemIdentity(of: metadata)
        return LocalAIActivityRecordVersion(
            device: identity.device,
            inode: identity.inode,
            generation: metadata.st_gen,
            byteCount: metadata.st_size,
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            contentEvidence: contentEvidence
        )
    }

    private func version(of result: LocalAIActivityRecordReadResult) -> LocalAIActivityRecordVersion {
        switch result {
        case let .record(snapshot): snapshot.version
        case let .oversized(version): version
        }
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & S_IFMT
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
                }
                written += count
            }
        }
    }

    private func readBounded(from descriptor: Int32) throws -> BoundedRecord {
        let limit = LocalAIActivityContract.maximumRecordBytes
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(4_096, limit + 1))
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count == 0 { return .record(data) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errno)
            }
            data.append(buffer, count: count)
        }
        return .oversized(data)
    }

    private func synchronize(_ descriptor: Int32) throws {
        let errorCode = hooks.synchronizeDescriptor(descriptor)
        guard errorCode == 0 else {
            throw SecureLocalAIActivityFileStoreError.filesystemOperationFailed(errorCode)
        }
    }

    private func recordName(_ id: UUID) -> String {
        "\(id.uuidString.lowercased()).json"
    }

    private func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty &&
            component != "." &&
            component != ".." &&
            !component.contains("/") &&
            !component.contains("\0")
    }
}

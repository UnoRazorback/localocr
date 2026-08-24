import Darwin
import Foundation
import LocalOCRCore
import PDFKit

public protocol StudioBatchItemExecuting: Sendable {
    func execute(
        _ item: StudioBatchItem,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL
}

public protocol StudioBatchOutputCommitting: Sendable {
    func temporaryURL(for finalURL: URL, outputRoot: URL) async throws -> URL

    func adoptPDF(at temporaryURL: URL, outputRoot: URL) async throws

    func writeText(
        _ text: String,
        to temporaryURL: URL,
        outputRoot: URL
    ) async throws

    func commit(
        _ temporaryURL: URL,
        to finalURL: URL,
        outputRoot: URL
    ) async throws

    func discard(_ temporaryURL: URL, outputRoot: URL) async
}

public actor StudioBatchExecutor: StudioBatchItemExecuting {
    private let client: any StudioOCRClient
    private let committer: any StudioBatchOutputCommitting

    public init(
        client: any StudioOCRClient,
        committer: any StudioBatchOutputCommitting = AtomicStudioBatchOutputCommitter()
    ) {
        self.client = client
        self.committer = committer
    }

    public func execute(
        _ item: StudioBatchItem,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        do {
            try Task.checkCancellation()
            let reservation = item.reservation
            let temporaryURL = try await committer.temporaryURL(
                for: reservation.finalURL,
                outputRoot: reservation.outputRoot
            )
            var deferredCleanupRequired = true
            defer {
                if deferredCleanupRequired {
                    Task {
                        await committer.discard(
                            temporaryURL,
                            outputRoot: reservation.outputRoot
                        )
                    }
                }
            }

            do {
                try Task.checkCancellation()
                let result = try await client.processDocument(
                    at: item.candidate.sourceURL,
                    progress: progress
                )
                try Task.checkCancellation()

                switch item.candidate.kind {
                case .pdf:
                    let generatedURL = try await client.makeSearchablePDF(
                        sourceURL: item.candidate.sourceURL,
                        destinationURL: temporaryURL,
                        progress: progress
                    )
                    // A normally-returning client call is the ownership handoff. Adopt before
                    // checking cancellation so a completed client write can be cleaned safely.
                    try await committer.adoptPDF(
                        at: temporaryURL,
                        outputRoot: reservation.outputRoot
                    )
                    guard generatedURL.standardizedFileURL == temporaryURL.standardizedFileURL else {
                        throw LocalOCRError.outputValidationFailed
                    }
                    try Task.checkCancellation()
                case .image:
                    try await committer.writeText(
                        result.text,
                        to: temporaryURL,
                        outputRoot: reservation.outputRoot
                    )
                    try Task.checkCancellation()
                }

                try Task.checkCancellation()
                try await committer.commit(
                    temporaryURL,
                    to: reservation.finalURL,
                    outputRoot: reservation.outputRoot
                )
                await committer.discard(temporaryURL, outputRoot: reservation.outputRoot)
                deferredCleanupRequired = false
                return reservation.finalURL
            } catch {
                await committer.discard(temporaryURL, outputRoot: reservation.outputRoot)
                deferredCleanupRequired = false
                throw error
            }
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        }
    }
}

public actor AtomicStudioBatchOutputCommitter: StudioBatchOutputCommitting {
    typealias OperationHook = @Sendable () async throws -> Void

    private struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectoryHandle: Sendable {
        let descriptor: Int32
        let nameFromParent: String?
        let identity: FileIdentity
    }

    private struct TemporaryReservation: Sendable {
        let temporaryURL: URL
        let temporaryName: String
        let stagingName: String
        let finalURL: URL
        let finalName: String
        let outputRoot: URL
        let directoryHandles: [DirectoryHandle]
        var ownedTemporaryIdentity: FileIdentity?

        var finalParentHandle: DirectoryHandle {
            directoryHandles[directoryHandles.count - 2]
        }

        var stagingHandle: DirectoryHandle {
            directoryHandles[directoryHandles.count - 1]
        }
    }

    private let temporaryName: @Sendable (URL) -> String
    private let beforeTextCreation: OperationHook
    private let beforeExclusiveCommit: OperationHook
    private var temporaryReservations: [String: TemporaryReservation] = [:]

    public init() {
        temporaryName = Self.defaultTemporaryName
        beforeTextCreation = {}
        beforeExclusiveCommit = {}
    }

    init(
        temporaryName: @escaping @Sendable (URL) -> String,
        beforeTextCreation: @escaping OperationHook = {},
        beforeExclusiveCommit: @escaping OperationHook = {}
    ) {
        self.temporaryName = temporaryName
        self.beforeTextCreation = beforeTextCreation
        self.beforeExclusiveCommit = beforeExclusiveCommit
    }

    init(
        beforeTextCreation: @escaping OperationHook = {},
        beforeExclusiveCommit: @escaping OperationHook = {}
    ) {
        temporaryName = Self.defaultTemporaryName
        self.beforeTextCreation = beforeTextCreation
        self.beforeExclusiveCommit = beforeExclusiveCommit
    }

    deinit {
        for reservation in temporaryReservations.values {
            closeHandles(reservation.directoryHandles)
        }
    }

    public func temporaryURL(for finalURL: URL, outputRoot: URL) throws -> URL {
        let root = try validatedPhysicalRoot(outputRoot)
        let final = try validatedFinal(finalURL, beneath: root.requested)
        let relativeFinalComponents = try descendantComponents(of: final, beneath: root.requested)
        var physicalFinal = root.physical
        for component in relativeFinalComponents {
            physicalFinal.appendPathComponent(component, isDirectory: false)
        }
        let finalParent = physicalFinal.deletingLastPathComponent()
        var handles = try openDirectoryChain(to: root.physical)
        var keepHandles = false
        defer {
            if !keepHandles {
                closeHandles(handles)
            }
        }

        try appendDescendantDirectoryHandles(
            to: &handles,
            through: finalParent,
            beneath: root.physical,
            createMissing: true
        )
        try reproveDirectoryChain(handles)
        let finalParentHandle = try requiredLastHandle(handles)
        if try entryMetadata(named: physicalFinal.lastPathComponent, beneath: finalParentHandle.descriptor) != nil {
            throw LocalOCRError.outputExists
        }

        for _ in 0..<128 {
            let stagingName = temporaryName(final)
            guard isSafeLeafName(stagingName) else {
                throw LocalOCRError.invalidDestination
            }
            let createStatus = stagingName.withCString { name in
                mkdirat(finalParentHandle.descriptor, name, 0o700)
            }
            guard createStatus == 0 else {
                if errno == EEXIST { continue }
                throw LocalOCRError.invalidDestination
            }

            do {
                let stagingHandle = try openDirectory(
                    named: stagingName,
                    beneath: finalParentHandle.descriptor
                )
                guard try isPrivateOwnedDirectory(stagingHandle) else {
                    Darwin.close(stagingHandle.descriptor)
                    throw LocalOCRError.invalidDestination
                }
                handles.append(stagingHandle)
                try reproveDirectoryChain(handles)

                let leafName = physicalFinal.lastPathComponent
                guard try entryMetadata(named: leafName, beneath: stagingHandle.descriptor) == nil else {
                    throw LocalOCRError.outputExists
                }
                let candidate = finalParent
                    .appendingPathComponent(stagingName, isDirectory: true)
                    .appendingPathComponent(leafName, isDirectory: false)
                guard candidate.deletingLastPathComponent().deletingLastPathComponent() == finalParent,
                      isStrictDescendant(candidate, of: root.physical)
                else {
                    throw LocalOCRError.invalidDestination
                }

                let reservation = TemporaryReservation(
                    temporaryURL: candidate,
                    temporaryName: leafName,
                    stagingName: stagingName,
                    finalURL: final,
                    finalName: physicalFinal.lastPathComponent,
                    outputRoot: root.requested,
                    directoryHandles: handles,
                    ownedTemporaryIdentity: nil
                )
                temporaryReservations[candidate.path] = reservation
                keepHandles = true
                return candidate
            } catch {
                if let stagingHandle = handles.last,
                   stagingHandle.nameFromParent == stagingName
                {
                    _ = stagingName.withCString { name in
                        unlinkat(finalParentHandle.descriptor, name, AT_REMOVEDIR)
                    }
                }
                throw error
            }
        }
        throw LocalOCRError.outputExists
    }

    public func adoptPDF(at temporaryURL: URL, outputRoot: URL) throws {
        var reservation = try validatedReservation(
            temporaryURL: temporaryURL,
            outputRoot: outputRoot
        )
        try reproveReservationDirectories(reservation)
        guard let metadata = try entryMetadata(
            named: reservation.temporaryName,
            beneath: reservation.stagingHandle.descriptor
        ) else {
            throw LocalOCRError.outputValidationFailed
        }

        // A normally-returning client call hands ownership of the exact staging entry to us.
        reservation.ownedTemporaryIdentity = identity(of: metadata)
        temporaryReservations[reservation.temporaryURL.path] = reservation
        guard fileType(metadata) == S_IFREG else {
            throw LocalOCRError.outputValidationFailed
        }
    }

    public func writeText(
        _ text: String,
        to temporaryURL: URL,
        outputRoot: URL
    ) async throws {
        var reservation = try validatedReservation(
            temporaryURL: temporaryURL,
            outputRoot: outputRoot
        )
        try reproveReservationDirectories(reservation)
        try await beforeTextCreation()
        try reproveReservationDirectories(reservation)
        guard reservation.ownedTemporaryIdentity == nil else {
            throw LocalOCRError.invalidDestination
        }

        let descriptor = reservation.temporaryName.withCString { name in
            openat(
                reservation.stagingHandle.descriptor,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw LocalOCRError.outputExists
            }
            throw LocalOCRError.invalidDestination
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              fileType(metadata) == S_IFREG
        else {
            throw LocalOCRError.outputValidationFailed
        }
        reservation.ownedTemporaryIdentity = identity(of: metadata)
        temporaryReservations[reservation.temporaryURL.path] = reservation

        let bytes = Data(text.utf8)
        do {
            try writeAll(bytes, to: descriptor)
            guard fsync(descriptor) == 0,
                  lseek(descriptor, 0, SEEK_SET) == 0,
                  try readAll(from: descriptor) == bytes
            else {
                throw LocalOCRError.outputValidationFailed
            }
        } catch let error as LocalOCRError {
            throw error
        } catch {
            throw LocalOCRError.outputValidationFailed
        }
    }

    public func commit(
        _ temporaryURL: URL,
        to finalURL: URL,
        outputRoot: URL
    ) async throws {
        let reservation = try validatedReservation(
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            outputRoot: outputRoot
        )
        try reproveReservationDirectories(reservation)
        let temporaryData = try validatedOwnedFileData(reservation)
        try validateOutputData(temporaryData, for: reservation.finalURL)

        try await beforeExclusiveCommit()

        // These are the final proofs before the descriptor-relative exclusive rename.
        try reproveReservationDirectories(reservation)
        try requireOwnedTemporaryIdentity(reservation)
        try Task.checkCancellation()
        let status = reservation.temporaryName.withCString { temporaryName in
            reservation.finalName.withCString { finalName in
                renameatx_np(
                    reservation.stagingHandle.descriptor,
                    temporaryName,
                    reservation.finalParentHandle.descriptor,
                    finalName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else {
            let renameError = errno
            if renameError == EEXIST {
                throw LocalOCRError.outputExists
            }
            throw LocalOCRError.invalidDestination
        }

        // The successful rename is irreversible success. Cleanup after this point is best effort.
        finishReservation(reservation, removeStagingDirectory: true)
    }

    public func discard(_ temporaryURL: URL, outputRoot: URL) {
        guard let reservation = temporaryReservations[temporaryURL.path],
              reservation.outputRoot == outputRoot.standardizedFileURL
        else {
            return
        }

        if let ownedIdentity = reservation.ownedTemporaryIdentity,
           descriptorStillMatches(reservation.stagingHandle),
           let currentMetadata = try? entryMetadata(
               named: reservation.temporaryName,
               beneath: reservation.stagingHandle.descriptor
           ),
           identity(of: currentMetadata) == ownedIdentity
        {
            _ = reservation.temporaryName.withCString { name in
                unlinkat(reservation.stagingHandle.descriptor, name, 0)
            }
        }

        finishReservation(reservation, removeStagingDirectory: true)
    }

    private static func defaultTemporaryName(for finalURL: URL) -> String {
        ".\(finalURL.lastPathComponent).\(UUID().uuidString).partial"
    }

    private func validatedReservation(
        temporaryURL: URL,
        finalURL: URL? = nil,
        outputRoot: URL
    ) throws -> TemporaryReservation {
        guard let reservation = temporaryReservations[temporaryURL.path],
              finalURL.map({ $0.standardizedFileURL == reservation.finalURL }) ?? true,
              outputRoot.standardizedFileURL == reservation.outputRoot
        else {
            throw LocalOCRError.invalidDestination
        }
        return reservation
    }

    private func validatedPhysicalRoot(_ outputRoot: URL) throws -> (requested: URL, physical: URL) {
        guard outputRoot.isFileURL else {
            throw LocalOCRError.invalidDestination
        }
        let requested = outputRoot.standardizedFileURL
        var metadata = stat()
        let status = requested.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &metadata)
        }
        guard status == 0, fileType(metadata) == S_IFDIR else {
            throw LocalOCRError.invalidDestination
        }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = requested.withUnsafeFileSystemRepresentation { path in
            guard let path else { return UnsafeMutablePointer<CChar>?.none }
            return realpath(path, &resolved)
        }
        guard result != nil else {
            throw LocalOCRError.invalidDestination
        }
        return (
            requested,
            URL(
                fileURLWithPath: String(
                    decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                ),
                isDirectory: true
            )
        )
    }

    private func validatedFinal(_ finalURL: URL, beneath outputRoot: URL) throws -> URL {
        guard finalURL.isFileURL else {
            throw LocalOCRError.invalidDestination
        }
        let final = finalURL.standardizedFileURL
        guard isStrictDescendant(final, of: outputRoot),
              isSafeLeafName(final.lastPathComponent)
        else {
            throw LocalOCRError.invalidDestination
        }
        return final
    }

    private func openDirectoryChain(to outputRoot: URL) throws -> [DirectoryHandle] {
        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw LocalOCRError.invalidDestination
        }
        var handles: [DirectoryHandle] = []
        var keepHandles = false
        defer {
            if !keepHandles {
                closeHandles(handles)
            }
        }

        do {
            handles.append(try directoryHandle(
                descriptor: rootDescriptor,
                nameFromParent: nil
            ))
            for component in outputRoot.pathComponents.dropFirst() {
                guard isSafeLeafName(component), let parent = handles.last else {
                    throw LocalOCRError.invalidDestination
                }
                handles.append(try openDirectory(
                    named: component,
                    beneath: parent.descriptor
                ))
            }
            try reproveDirectoryChain(handles)
            keepHandles = true
            return handles
        } catch {
            if handles.isEmpty {
                Darwin.close(rootDescriptor)
            }
            throw error
        }
    }

    private func appendDescendantDirectoryHandles(
        to handles: inout [DirectoryHandle],
        through directory: URL,
        beneath outputRoot: URL,
        createMissing: Bool
    ) throws {
        let components = try descendantComponents(of: directory, beneath: outputRoot)
        for component in components {
            guard let parent = handles.last else {
                throw LocalOCRError.invalidDestination
            }
            do {
                handles.append(try openDirectory(named: component, beneath: parent.descriptor))
            } catch let error as POSIXLookupError where error.code == ENOENT && createMissing {
                let status = component.withCString { name in
                    mkdirat(parent.descriptor, name, 0o755)
                }
                guard status == 0 || errno == EEXIST else {
                    throw LocalOCRError.invalidDestination
                }
                handles.append(try openDirectory(named: component, beneath: parent.descriptor))
            } catch {
                throw LocalOCRError.invalidDestination
            }
        }
    }

    private func openDirectory(named name: String, beneath parentDescriptor: Int32) throws -> DirectoryHandle {
        let descriptor = name.withCString { component in
            openat(parentDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXLookupError(code: errno, name: name)
        }
        do {
            return try directoryHandle(descriptor: descriptor, nameFromParent: name)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func directoryHandle(
        descriptor: Int32,
        nameFromParent: String?
    ) throws -> DirectoryHandle {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              fileType(metadata) == S_IFDIR
        else {
            throw LocalOCRError.invalidDestination
        }
        return DirectoryHandle(
            descriptor: descriptor,
            nameFromParent: nameFromParent,
            identity: identity(of: metadata)
        )
    }

    private func requiredLastHandle(_ handles: [DirectoryHandle]) throws -> DirectoryHandle {
        guard let handle = handles.last else {
            throw LocalOCRError.invalidDestination
        }
        return handle
    }

    private func reproveReservationDirectories(_ reservation: TemporaryReservation) throws {
        try reproveDirectoryChain(reservation.directoryHandles)
    }

    private func reproveDirectoryChain(_ handles: [DirectoryHandle]) throws {
        guard !handles.isEmpty else {
            throw LocalOCRError.invalidDestination
        }
        for (index, handle) in handles.enumerated() {
            guard descriptorStillMatches(handle) else {
                throw LocalOCRError.invalidDestination
            }
            guard index > 0 else { continue }
            let parent = handles[index - 1]
            guard let name = handle.nameFromParent,
                  let metadata = try entryMetadata(named: name, beneath: parent.descriptor),
                  fileType(metadata) == S_IFDIR,
                  identity(of: metadata) == handle.identity
            else {
                throw LocalOCRError.invalidDestination
            }
        }
    }

    private func descriptorStillMatches(_ handle: DirectoryHandle) -> Bool {
        var metadata = stat()
        return fstat(handle.descriptor, &metadata) == 0 &&
            fileType(metadata) == S_IFDIR &&
            identity(of: metadata) == handle.identity
    }

    private func isPrivateOwnedDirectory(_ handle: DirectoryHandle) throws -> Bool {
        var metadata = stat()
        guard fstat(handle.descriptor, &metadata) == 0 else {
            throw LocalOCRError.invalidDestination
        }
        return fileType(metadata) == S_IFDIR &&
            metadata.st_uid == geteuid() &&
            metadata.st_mode & 0o777 == 0o700
    }

    private func entryMetadata(named name: String, beneath descriptor: Int32) throws -> stat? {
        var metadata = stat()
        let status = name.withCString { component in
            fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw LocalOCRError.invalidDestination
    }

    private func validatedOwnedFileData(_ reservation: TemporaryReservation) throws -> Data {
        guard let expectedIdentity = reservation.ownedTemporaryIdentity else {
            throw LocalOCRError.outputValidationFailed
        }
        let descriptor = reservation.temporaryName.withCString { name in
            openat(reservation.stagingHandle.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LocalOCRError.outputValidationFailed
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              fileType(metadata) == S_IFREG,
              identity(of: metadata) == expectedIdentity
        else {
            throw LocalOCRError.outputValidationFailed
        }
        do {
            return try readAll(from: descriptor)
        } catch {
            throw LocalOCRError.outputValidationFailed
        }
    }

    private func requireOwnedTemporaryIdentity(_ reservation: TemporaryReservation) throws {
        guard let expectedIdentity = reservation.ownedTemporaryIdentity,
              let metadata = try entryMetadata(
                  named: reservation.temporaryName,
                  beneath: reservation.stagingHandle.descriptor
              ),
              fileType(metadata) == S_IFREG,
              identity(of: metadata) == expectedIdentity
        else {
            throw LocalOCRError.outputValidationFailed
        }
    }

    private func validateOutputData(_ data: Data, for finalURL: URL) throws {
        switch finalURL.pathExtension.lowercased() {
        case "pdf":
            guard data.starts(with: Data("%PDF-".utf8)),
                  let document = PDFDocument(data: data),
                  document.pageCount > 0
            else {
                throw LocalOCRError.outputValidationFailed
            }
        case "txt":
            guard String(data: data, encoding: .utf8) != nil else {
                throw LocalOCRError.outputValidationFailed
            }
        default:
            throw LocalOCRError.invalidDestination
        }
    }

    private func finishReservation(
        _ reservation: TemporaryReservation,
        removeStagingDirectory: Bool
    ) {
        temporaryReservations.removeValue(forKey: reservation.temporaryURL.path)
        if removeStagingDirectory,
           descriptorStillMatches(reservation.finalParentHandle),
           descriptorStillMatches(reservation.stagingHandle),
           let currentMetadata = try? entryMetadata(
               named: reservation.stagingName,
               beneath: reservation.finalParentHandle.descriptor
           ),
           fileType(currentMetadata) == S_IFDIR,
           identity(of: currentMetadata) == reservation.stagingHandle.identity
        {
            _ = reservation.stagingName.withCString { name in
                unlinkat(reservation.finalParentHandle.descriptor, name, AT_REMOVEDIR)
            }
        }
        closeHandles(reservation.directoryHandles)
    }

    nonisolated private func closeHandles(_ handles: [DirectoryHandle]) {
        for handle in handles.reversed() {
            Darwin.close(handle.descriptor)
        }
    }

    private func descendantComponents(of url: URL, beneath outputRoot: URL) throws -> [String] {
        guard url.path == outputRoot.path || isStrictDescendant(url, of: outputRoot) else {
            throw LocalOCRError.invalidDestination
        }
        guard url.path != outputRoot.path else { return [] }
        let rootPrefix = outputRoot.path.hasSuffix("/") ? outputRoot.path : outputRoot.path + "/"
        let relative = url.path.dropFirst(rootPrefix.count)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ isSafeLeafName($0) }) else {
            throw LocalOCRError.invalidDestination
        }
        return components
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    throw LocalOCRError.outputValidationFailed
                }
                written += count
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalOCRError.outputValidationFailed
            }
            data.append(buffer, count: count)
        }
    }

    private func identity(of metadata: stat) -> FileIdentity {
        FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    private func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & S_IFMT
    }
}

private struct POSIXLookupError: Error {
    let code: Int32
    let name: String
}

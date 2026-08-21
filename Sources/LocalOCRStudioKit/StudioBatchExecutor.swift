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
    private struct RootIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct TemporaryReservation: Sendable {
        let temporaryURL: URL
        let finalURL: URL
        let outputRoot: URL
        let rootIdentity: RootIdentity
    }

    private let temporaryName: @Sendable (URL) -> String
    private var temporaryReservations: [URL: TemporaryReservation] = [:]

    public init() {
        temporaryName = { finalURL in
            ".\(finalURL.lastPathComponent).\(UUID().uuidString).partial"
        }
    }

    init(temporaryName: @escaping @Sendable (URL) -> String) {
        self.temporaryName = temporaryName
    }

    public func temporaryURL(for finalURL: URL, outputRoot: URL) throws -> URL {
        let root = try validatedRoot(outputRoot)
        let final = try validatedFinal(finalURL, beneath: root.url)
        try createAndValidateAncestors(
            through: final.deletingLastPathComponent(),
            beneath: root.url,
            rootIdentity: root.identity
        )
        try requireRootIdentity(root.identity, at: root.url)

        if pathEntryExists(final) {
            throw LocalOCRError.outputExists
        }

        for _ in 0..<128 {
            let name = temporaryName(final)
            guard isSafeLeafName(name) else {
                throw LocalOCRError.invalidDestination
            }
            let candidate = final.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent() == final.deletingLastPathComponent(),
                  isStrictDescendant(candidate, of: root.url)
            else {
                throw LocalOCRError.invalidDestination
            }
            guard !pathEntryExists(candidate), temporaryReservations[candidate] == nil else {
                continue
            }

            temporaryReservations[candidate] = TemporaryReservation(
                temporaryURL: candidate,
                finalURL: final,
                outputRoot: root.url,
                rootIdentity: root.identity
            )
            return candidate
        }
        throw LocalOCRError.outputExists
    }

    public func writeText(
        _ text: String,
        to temporaryURL: URL,
        outputRoot: URL
    ) throws {
        let reservation = try validatedReservation(
            temporaryURL: temporaryURL,
            outputRoot: outputRoot
        )
        try revalidate(reservation)

        let descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw LocalOCRError.outputExists
            }
            throw LocalOCRError.invalidDestination
        }
        defer { Darwin.close(descriptor) }

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
    ) throws {
        let reservation = try validatedReservation(
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            outputRoot: outputRoot
        )
        try revalidate(reservation)
        let temporaryData = try validatedRegularFileData(at: reservation.temporaryURL)
        switch reservation.finalURL.pathExtension.lowercased() {
        case "pdf":
            guard temporaryData.starts(with: Data("%PDF-".utf8)),
                  let document = PDFDocument(data: temporaryData),
                  document.pageCount > 0
            else {
                throw LocalOCRError.outputValidationFailed
            }
        case "txt":
            guard String(data: temporaryData, encoding: .utf8) != nil else {
                throw LocalOCRError.outputValidationFailed
            }
        default:
            throw LocalOCRError.invalidDestination
        }

        if pathEntryExists(reservation.finalURL) {
            throw LocalOCRError.outputExists
        }

        // This is intentionally the last filesystem validation before the exclusive rename.
        try revalidate(reservation)
        let status = reservation.temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            reservation.finalURL.withUnsafeFileSystemRepresentation { finalPath in
                guard let temporaryPath, let finalPath else { return EINVAL }
                return renamex_np(temporaryPath, finalPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let renameError = errno
            if renameError == EEXIST {
                throw LocalOCRError.outputExists
            }
            throw LocalOCRError.invalidDestination
        }
        temporaryReservations.removeValue(forKey: reservation.temporaryURL)
    }

    public func discard(_ temporaryURL: URL, outputRoot: URL) {
        let temporary = temporaryURL.standardizedFileURL
        guard let reservation = temporaryReservations[temporary],
              reservation.outputRoot == outputRoot.standardizedFileURL
        else {
            return
        }
        defer { temporaryReservations.removeValue(forKey: temporary) }

        guard (try? requireRootIdentity(reservation.rootIdentity, at: reservation.outputRoot)) != nil,
              (try? validateExistingAncestors(
                  through: temporary.deletingLastPathComponent(),
                  beneath: reservation.outputRoot,
                  rootIdentity: reservation.rootIdentity
              )) != nil
        else {
            return
        }

        var metadata = stat()
        guard lstatPath(temporary, into: &metadata) == 0 else { return }
        _ = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.unlink(path)
        }
    }

    private func validatedReservation(
        temporaryURL: URL,
        finalURL: URL? = nil,
        outputRoot: URL
    ) throws -> TemporaryReservation {
        let temporary = temporaryURL.standardizedFileURL
        guard let reservation = temporaryReservations[temporary],
              finalURL.map({ $0.standardizedFileURL == reservation.finalURL }) ?? true,
              outputRoot.standardizedFileURL == reservation.outputRoot
        else {
            throw LocalOCRError.invalidDestination
        }
        return reservation
    }

    private func revalidate(_ reservation: TemporaryReservation) throws {
        try requireRootIdentity(reservation.rootIdentity, at: reservation.outputRoot)
        guard isStrictDescendant(reservation.finalURL, of: reservation.outputRoot),
              isStrictDescendant(reservation.temporaryURL, of: reservation.outputRoot),
              reservation.temporaryURL.deletingLastPathComponent()
                == reservation.finalURL.deletingLastPathComponent()
        else {
            throw LocalOCRError.invalidDestination
        }
        try validateExistingAncestors(
            through: reservation.finalURL.deletingLastPathComponent(),
            beneath: reservation.outputRoot,
            rootIdentity: reservation.rootIdentity
        )
        try requireRootIdentity(reservation.rootIdentity, at: reservation.outputRoot)
    }

    private func validatedRoot(_ outputRoot: URL) throws -> (url: URL, identity: RootIdentity) {
        guard outputRoot.isFileURL else {
            throw LocalOCRError.invalidDestination
        }
        let root = outputRoot.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw LocalOCRError.invalidDestination
        }
        var metadata = stat()
        guard lstatPath(root, into: &metadata) == 0,
              fileType(metadata) == S_IFDIR
        else {
            throw LocalOCRError.invalidDestination
        }
        return (
            root,
            RootIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
        )
    }

    private func requireRootIdentity(_ expected: RootIdentity, at outputRoot: URL) throws {
        let current = try validatedRoot(outputRoot)
        guard current.identity == expected else {
            throw LocalOCRError.invalidDestination
        }
    }

    private func validatedFinal(_ finalURL: URL, beneath outputRoot: URL) throws -> URL {
        guard finalURL.isFileURL else {
            throw LocalOCRError.invalidDestination
        }
        let final = finalURL.standardizedFileURL
        guard isStrictDescendant(final, of: outputRoot),
              !final.lastPathComponent.isEmpty
        else {
            throw LocalOCRError.invalidDestination
        }
        return final
    }

    private func createAndValidateAncestors(
        through parent: URL,
        beneath outputRoot: URL,
        rootIdentity: RootIdentity
    ) throws {
        let components = try descendantComponents(of: parent, beneath: outputRoot)
        try traverseAncestors(
            components,
            beneath: outputRoot,
            rootIdentity: rootIdentity,
            createMissing: true
        )
    }

    private func validateExistingAncestors(
        through parent: URL,
        beneath outputRoot: URL,
        rootIdentity: RootIdentity
    ) throws {
        let components = try descendantComponents(of: parent, beneath: outputRoot)
        try traverseAncestors(
            components,
            beneath: outputRoot,
            rootIdentity: rootIdentity,
            createMissing: false
        )
    }

    private func traverseAncestors(
        _ components: [String],
        beneath outputRoot: URL,
        rootIdentity: RootIdentity,
        createMissing: Bool
    ) throws {
        var descriptor = outputRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LocalOCRError.invalidDestination
        }
        defer { Darwin.close(descriptor) }

        var rootMetadata = stat()
        guard fstat(descriptor, &rootMetadata) == 0,
              fileType(rootMetadata) == S_IFDIR,
              RootIdentity(
                  device: UInt64(rootMetadata.st_dev),
                  inode: UInt64(rootMetadata.st_ino)
              ) == rootIdentity
        else {
            throw LocalOCRError.invalidDestination
        }

        for component in components {
            var nextDescriptor = component.withCString { name in
                openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if nextDescriptor < 0, errno == ENOENT, createMissing {
                let createStatus = component.withCString { name in
                    mkdirat(descriptor, name, 0o755)
                }
                guard createStatus == 0 || errno == EEXIST else {
                    throw LocalOCRError.invalidDestination
                }
                nextDescriptor = component.withCString { name in
                    openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            guard nextDescriptor >= 0 else {
                throw LocalOCRError.invalidDestination
            }

            var metadata = stat()
            guard fstat(nextDescriptor, &metadata) == 0,
                  fileType(metadata) == S_IFDIR
            else {
                Darwin.close(nextDescriptor)
                throw LocalOCRError.invalidDestination
            }
            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
    }

    private func descendantComponents(of url: URL, beneath outputRoot: URL) throws -> [String] {
        let standardized = url.standardizedFileURL
        guard standardized == outputRoot || isStrictDescendant(standardized, of: outputRoot) else {
            throw LocalOCRError.invalidDestination
        }
        guard standardized != outputRoot else { return [] }
        let rootPrefix = outputRoot.path.hasSuffix("/") ? outputRoot.path : outputRoot.path + "/"
        let relative = standardized.path.dropFirst(rootPrefix.count)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ isSafeLeafName($0) }) else {
            throw LocalOCRError.invalidDestination
        }
        return components
    }

    private func validatedRegularFileData(at url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LocalOCRError.outputValidationFailed
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              fileType(metadata) == S_IFREG
        else {
            throw LocalOCRError.outputValidationFailed
        }
        do {
            return try readAll(from: descriptor)
        } catch {
            throw LocalOCRError.outputValidationFailed
        }
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

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    private func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstatPath(url, into: &metadata) == 0
    }

    private func lstatPath(_ url: URL, into metadata: inout stat) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & S_IFMT
    }
}

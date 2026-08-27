import Darwin
import Foundation

public enum ExternalDataConsentStoreError: Error, Sendable {
    case invalidReceiptPath
    case missingPath
    case insecureFilesystemState
    case filesystemOperationFailed(Int32)
    case invalidReceiptEncoding
}

struct ExternalDataConsentStoreHooks: Sendable {
    typealias OperationHook = @Sendable () throws -> Void
    typealias DescriptorSync = @Sendable (Int32) -> Int32

    let beforeAcceptReproof: OperationHook
    let beforeAcceptFinalMutation: OperationHook
    let beforeRevokeReproof: OperationHook
    let beforeRevokeFinalMutation: OperationHook
    let beforeTemporaryCleanupFinalMutation: OperationHook
    let synchronizeDescriptor: DescriptorSync

    init(
        beforeAcceptReproof: @escaping OperationHook = {},
        beforeAcceptFinalMutation: @escaping OperationHook = {},
        beforeRevokeReproof: @escaping OperationHook = {},
        beforeRevokeFinalMutation: @escaping OperationHook = {},
        beforeTemporaryCleanupFinalMutation: @escaping OperationHook = {},
        synchronizeDescriptor: @escaping DescriptorSync = { fsync($0) }
    ) {
        self.beforeAcceptReproof = beforeAcceptReproof
        self.beforeAcceptFinalMutation = beforeAcceptFinalMutation
        self.beforeRevokeReproof = beforeRevokeReproof
        self.beforeRevokeFinalMutation = beforeRevokeFinalMutation
        self.beforeTemporaryCleanupFinalMutation = beforeTemporaryCleanupFinalMutation
        self.synchronizeDescriptor = synchronizeDescriptor
    }
}

public actor ExternalDataConsentStore: ExternalDataConsentStoring {
    private struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectoryHandle: Sendable {
        let descriptor: Int32
        let nameFromParent: String?
        let identity: FileIdentity
    }

    private struct OpenedReceipt: Sendable {
        let descriptor: Int32
        let identity: FileIdentity
    }

    private struct QuarantinedEntry: Sendable {
        let name: String
        let identity: FileIdentity
    }

    public static var defaultReceiptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/com.rayconsulting.localocr",
                directoryHint: .isDirectory
            )
            .appending(path: "mcp-consent.json", directoryHint: .notDirectory)
    }

    public nonisolated let receiptURL: URL

    private let receiptName: String
    private let directoryComponents: [String]
    private let expectedReceiptOwnerID: uid_t
    private let hooks: ExternalDataConsentStoreHooks

    public init(receiptURL: URL = ExternalDataConsentStore.defaultReceiptURL) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        hooks = ExternalDataConsentStoreHooks()
    }

    init(receiptURL: URL, expectedReceiptOwnerID: uid_t) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        self.expectedReceiptOwnerID = expectedReceiptOwnerID
        hooks = ExternalDataConsentStoreHooks()
    }

    init(
        receiptURL: URL,
        beforeAcceptRename: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        hooks = ExternalDataConsentStoreHooks(beforeAcceptReproof: beforeAcceptRename)
    }

    init(
        receiptURL: URL,
        beforeRevokeUnlink: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        hooks = ExternalDataConsentStoreHooks(beforeRevokeReproof: beforeRevokeUnlink)
    }

    init(receiptURL: URL, hooks: ExternalDataConsentStoreHooks) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        self.hooks = hooks
    }

    public func status() async -> ExternalDataConsentStatus {
        do {
            let handles = try openDirectoryChain(createApplicationDirectory: false)
            defer { close(handles) }
            try reprove(handles)
            let parent = try requiredParent(in: handles)
            let openedReceipt = try openValidatedReceipt(beneath: parent.descriptor)
            defer { Darwin.close(openedReceipt.descriptor) }
            let data = try readAll(from: openedReceipt.descriptor)
            try reprove(handles)
            try requireEntry(
                named: receiptName,
                beneath: parent.descriptor,
                matches: openedReceipt.identity
            )
            let receipt = try decodeReceipt(data)
            guard receipt.schemaVersion == ExternalDataConsentReceipt.currentSchemaVersion,
                  receipt.policyVersion == ExternalDataConsentReceipt.currentPolicyVersion,
                  receipt.externalProviderRiskAccepted,
                  receipt.documentToolAccessAccepted
            else {
                return .required
            }
            return .current(receipt)
        } catch {
            return .required
        }
    }

    public func acceptBothStatements(at date: Date) async throws {
        let receipt = ExternalDataConsentReceipt(
            schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
            policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
            acceptedAt: date,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        let data = try encodeReceipt(receipt)
        let handles = try openDirectoryChain(createApplicationDirectory: true)
        defer { close(handles) }
        try reprove(handles)
        let parent = try requiredParent(in: handles)
        let existingReceipt: OpenedReceipt?
        do {
            existingReceipt = try openValidatedReceipt(beneath: parent.descriptor)
        } catch ExternalDataConsentStoreError.missingPath {
            existingReceipt = nil
        }
        defer {
            if let existingReceipt {
                Darwin.close(existingReceipt.descriptor)
            }
        }

        let temporary = try createTemporaryReceipt(beneath: parent.descriptor)
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary.descriptor)
            if shouldRemoveTemporary {
                try? quarantineAndRemove(
                    named: temporary.name,
                    beneath: parent.descriptor,
                    expectedIdentity: temporary.identity,
                    beforeFinalMutation: hooks.beforeTemporaryCleanupFinalMutation
                )
            }
        }

        try writeAll(data, to: temporary.descriptor)
        try synchronize(temporary.descriptor)

        try hooks.beforeAcceptReproof()
        try reprove(handles)
        if let existingReceipt {
            try requireEntry(
                named: receiptName,
                beneath: parent.descriptor,
                matches: existingReceipt.identity
            )
        } else if try entryMetadata(named: receiptName, beneath: parent.descriptor) != nil {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        try requireEntry(
            named: temporary.name,
            beneath: parent.descriptor,
            matches: temporary.identity
        )
        try hooks.beforeAcceptFinalMutation()

        if let existingReceipt {
            try swapEntries(
                temporary.name,
                receiptName,
                beneath: parent.descriptor
            )
            let commitMatches = entryIdentity(
                named: receiptName,
                beneath: parent.descriptor
            ) == temporary.identity && entryIdentity(
                named: temporary.name,
                beneath: parent.descriptor
            ) == existingReceipt.identity
            do {
                guard commitMatches else {
                    throw ExternalDataConsentStoreError.insecureFilesystemState
                }
                try reprove(handles)
            } catch {
                recoverFailedSwap(
                    temporaryName: temporary.name,
                    expectedExistingIdentity: existingReceipt.identity,
                    beneath: parent.descriptor
                )
                throw error
            }

            shouldRemoveTemporary = false
            do {
                try synchronize(parent.descriptor)
            } catch {
                recoverFailedSwap(
                    temporaryName: temporary.name,
                    expectedExistingIdentity: existingReceipt.identity,
                    beneath: parent.descriptor
                )
                shouldRemoveTemporary = true
                throw error
            }
            do {
                try quarantineAndRemove(
                    named: temporary.name,
                    beneath: parent.descriptor,
                    expectedIdentity: existingReceipt.identity,
                    beforeFinalMutation: hooks.beforeTemporaryCleanupFinalMutation
                )
            } catch {
                try? quarantineAndRemove(
                    named: receiptName,
                    beneath: parent.descriptor,
                    expectedIdentity: temporary.identity,
                    beforeFinalMutation: {}
                )
                throw error
            }
            do {
                try reprove(handles)
                try requireEntry(
                    named: receiptName,
                    beneath: parent.descriptor,
                    matches: temporary.identity
                )
            } catch {
                try? quarantineAndRemove(
                    named: receiptName,
                    beneath: parent.descriptor,
                    expectedIdentity: temporary.identity,
                    beforeFinalMutation: {}
                )
                throw error
            }
        } else {
            let renameStatus = exclusiveRename(
                temporary.name,
                receiptName,
                beneath: parent.descriptor
            )
            guard renameStatus == 0 else {
                let renameError = errno
                try? quarantineCurrentWithoutDeleting(beneath: parent.descriptor)
                if renameError == EEXIST || renameError == ELOOP {
                    throw ExternalDataConsentStoreError.insecureFilesystemState
                }
                throw ExternalDataConsentStoreError.filesystemOperationFailed(renameError)
            }
            shouldRemoveTemporary = false
            guard entryIdentity(
                named: receiptName,
                beneath: parent.descriptor
            ) == temporary.identity else {
                try? quarantineCurrentWithoutDeleting(beneath: parent.descriptor)
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            do {
                try reprove(handles)
                try synchronize(parent.descriptor)
                try requireEntry(
                    named: receiptName,
                    beneath: parent.descriptor,
                    matches: temporary.identity
                )
            } catch {
                try? quarantineAndRemove(
                    named: receiptName,
                    beneath: parent.descriptor,
                    expectedIdentity: temporary.identity,
                    beforeFinalMutation: {}
                )
                throw error
            }
        }
    }

    public func revoke() async throws {
        let handles: [DirectoryHandle]
        do {
            handles = try openDirectoryChain(createApplicationDirectory: false)
        } catch ExternalDataConsentStoreError.missingPath {
            return
        }
        defer { close(handles) }
        try reprove(handles)
        let parent = try requiredParent(in: handles)
        let openedReceipt: OpenedReceipt
        do {
            openedReceipt = try openValidatedReceipt(beneath: parent.descriptor)
        } catch ExternalDataConsentStoreError.missingPath {
            return
        }
        defer { Darwin.close(openedReceipt.descriptor) }

        try hooks.beforeRevokeReproof()
        try reprove(handles)
        try requireEntry(
            named: receiptName,
            beneath: parent.descriptor,
            matches: openedReceipt.identity
        )
        let quarantine = try moveToQuarantine(
            named: receiptName,
            beneath: parent.descriptor,
            expectedIdentity: openedReceipt.identity,
            beforeFinalMutation: hooks.beforeRevokeFinalMutation
        )
        try reprove(handles)
        try removeQuarantinedEntry(quarantine, beneath: parent.descriptor)
    }

    private func openDirectoryChain(createApplicationDirectory: Bool) throws -> [DirectoryHandle] {
        guard receiptURL.isFileURL,
              receiptURL.path.hasPrefix("/"),
              !directoryComponents.isEmpty,
              isSafeComponent(receiptName)
        else {
            throw ExternalDataConsentStoreError.invalidReceiptPath
        }

        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }
        var handles: [DirectoryHandle] = []
        var keepHandles = false
        defer {
            if !keepHandles {
                close(handles)
            }
        }

        do {
            handles.append(try directoryHandle(
                descriptor: rootDescriptor,
                nameFromParent: nil
            ))
            for (index, component) in directoryComponents.enumerated() {
                guard isSafeComponent(component), let parent = handles.last else {
                    throw ExternalDataConsentStoreError.invalidReceiptPath
                }
                let isApplicationDirectory = index == directoryComponents.count - 1
                var wasCreated = false
                let metadata = try entryMetadata(named: component, beneath: parent.descriptor)
                if metadata == nil {
                    guard createApplicationDirectory, isApplicationDirectory else {
                        throw ExternalDataConsentStoreError.missingPath
                    }
                    let mkdirStatus = component.withCString { name in
                        mkdirat(parent.descriptor, name, 0o700)
                    }
                    guard mkdirStatus == 0 else {
                        if errno == EEXIST {
                            throw ExternalDataConsentStoreError.insecureFilesystemState
                        }
                        throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
                    }
                    wasCreated = true
                } else {
                    guard fileType(metadata!) == S_IFDIR else {
                        throw ExternalDataConsentStoreError.insecureFilesystemState
                    }
                }

                let child = try openDirectory(named: component, beneath: parent.descriptor)
                do {
                    if wasCreated {
                        guard fchmod(child.descriptor, 0o700) == 0 else {
                            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
                        }
                    }
                    if isApplicationDirectory {
                        try requirePrivateApplicationDirectory(child)
                    }
                    if wasCreated {
                        try synchronize(parent.descriptor)
                    }
                    handles.append(child)
                } catch {
                    Darwin.close(child.descriptor)
                    throw error
                }
            }
            try reprove(handles)
            keepHandles = true
            return handles
        } catch {
            if handles.isEmpty {
                Darwin.close(rootDescriptor)
            }
            throw error
        }
    }

    private func openDirectory(named name: String, beneath parentDescriptor: Int32) throws -> DirectoryHandle {
        guard let beforeOpen = try entryMetadata(named: name, beneath: parentDescriptor),
              fileType(beforeOpen) == S_IFDIR
        else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        let descriptor = name.withCString { component in
            openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }
        do {
            let handle = try directoryHandle(descriptor: descriptor, nameFromParent: name)
            guard handle.identity == identity(of: beforeOpen) else {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            return handle
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
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        return DirectoryHandle(
            descriptor: descriptor,
            nameFromParent: nameFromParent,
            identity: identity(of: metadata)
        )
    }

    private func requirePrivateApplicationDirectory(_ handle: DirectoryHandle) throws {
        var metadata = stat()
        guard fstat(handle.descriptor, &metadata) == 0,
              fileType(metadata) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == 0o700
        else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
    }

    private func reprove(_ handles: [DirectoryHandle]) throws {
        guard !handles.isEmpty else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        for (index, handle) in handles.enumerated() {
            var metadata = stat()
            guard fstat(handle.descriptor, &metadata) == 0,
                  fileType(metadata) == S_IFDIR,
                  identity(of: metadata) == handle.identity
            else {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            guard index > 0 else { continue }
            let parent = handles[index - 1]
            guard let name = handle.nameFromParent,
                  let current = try entryMetadata(named: name, beneath: parent.descriptor),
                  fileType(current) == S_IFDIR,
                  identity(of: current) == handle.identity
            else {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
        }
        if let applicationDirectory = handles.last {
            try requirePrivateApplicationDirectory(applicationDirectory)
        }
    }

    private func requiredParent(in handles: [DirectoryHandle]) throws -> DirectoryHandle {
        guard let parent = handles.last else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        return parent
    }

    private func openValidatedReceipt(beneath parentDescriptor: Int32) throws -> OpenedReceipt {
        guard let beforeOpen = try entryMetadata(named: receiptName, beneath: parentDescriptor) else {
            throw ExternalDataConsentStoreError.missingPath
        }
        try validateReceiptMetadata(beforeOpen)
        let descriptor = receiptName.withCString { name in
            openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
            }
            try validateReceiptMetadata(metadata)
            let openedIdentity = identity(of: metadata)
            guard openedIdentity == identity(of: beforeOpen) else {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            return OpenedReceipt(descriptor: descriptor, identity: openedIdentity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateReceiptMetadata(_ metadata: stat) throws {
        guard fileType(metadata) == S_IFREG,
              metadata.st_uid == expectedReceiptOwnerID,
              metadata.st_mode & 0o7777 == 0o600
        else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
    }

    private func createTemporaryReceipt(
        beneath parentDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String, identity: FileIdentity) {
        for _ in 0..<32 {
            let name = ".\(receiptName).\(UUID().uuidString).tmp"
            let descriptor = name.withCString { temporaryName in
                openat(
                    parentDescriptor,
                    temporaryName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
            }
            do {
                guard fchmod(descriptor, 0o600) == 0 else {
                    throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
                }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0,
                      fileType(metadata) == S_IFREG,
                      metadata.st_uid == geteuid(),
                      metadata.st_mode & 0o7777 == 0o600
                else {
                    throw ExternalDataConsentStoreError.insecureFilesystemState
                }
                return (descriptor, name, identity(of: metadata))
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        throw ExternalDataConsentStoreError.insecureFilesystemState
    }

    private func requireEntry(
        named name: String,
        beneath parentDescriptor: Int32,
        matches expectedIdentity: FileIdentity
    ) throws {
        guard let metadata = try entryMetadata(named: name, beneath: parentDescriptor),
              fileType(metadata) == S_IFREG,
              identity(of: metadata) == expectedIdentity
        else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        while hooks.synchronizeDescriptor(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw ExternalDataConsentStoreError.filesystemOperationFailed(code)
        }
    }

    private func swapEntries(
        _ firstName: String,
        _ secondName: String,
        beneath parentDescriptor: Int32
    ) throws {
        let status = firstName.withCString { first in
            secondName.withCString { second in
                renameatx_np(
                    parentDescriptor,
                    first,
                    parentDescriptor,
                    second,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
        guard status == 0 else {
            let code = errno
            if code == ELOOP || code == ENOENT {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            throw ExternalDataConsentStoreError.filesystemOperationFailed(code)
        }
    }

    private func exclusiveRename(
        _ sourceName: String,
        _ destinationName: String,
        beneath parentDescriptor: Int32
    ) -> Int32 {
        sourceName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
    }

    private func entryIdentity(
        named name: String,
        beneath parentDescriptor: Int32
    ) -> FileIdentity? {
        do {
            guard let metadata = try entryMetadata(named: name, beneath: parentDescriptor),
                  fileType(metadata) == S_IFREG
            else {
                return nil
            }
            return identity(of: metadata)
        } catch {
            return nil
        }
    }

    private func moveToQuarantine(
        named sourceName: String,
        beneath parentDescriptor: Int32,
        expectedIdentity: FileIdentity,
        beforeFinalMutation: ExternalDataConsentStoreHooks.OperationHook
    ) throws -> QuarantinedEntry {
        for _ in 0..<32 {
            let quarantineName = ".\(receiptName).\(UUID().uuidString).quarantine"
            try beforeFinalMutation()
            let status = exclusiveRename(sourceName, quarantineName, beneath: parentDescriptor)
            if status != 0 {
                let code = errno
                if code == EEXIST { continue }
                if code == ELOOP || code == ENOENT {
                    throw ExternalDataConsentStoreError.insecureFilesystemState
                }
                throw ExternalDataConsentStoreError.filesystemOperationFailed(code)
            }

            try synchronize(parentDescriptor)
            guard entryIdentity(named: quarantineName, beneath: parentDescriptor) == expectedIdentity else {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            return QuarantinedEntry(name: quarantineName, identity: expectedIdentity)
        }
        throw ExternalDataConsentStoreError.insecureFilesystemState
    }

    private func removeQuarantinedEntry(
        _ quarantine: QuarantinedEntry,
        beneath parentDescriptor: Int32
    ) throws {
        guard entryIdentity(named: quarantine.name, beneath: parentDescriptor) == quarantine.identity else {
            throw ExternalDataConsentStoreError.insecureFilesystemState
        }
        let status = quarantine.name.withCString { name in
            unlinkat(
                parentDescriptor,
                name,
                AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH | AT_UNIQUE
            )
        }
        guard status == 0 else {
            let code = errno
            if code == ELOOP || code == ENOENT {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            throw ExternalDataConsentStoreError.filesystemOperationFailed(code)
        }
        try synchronize(parentDescriptor)
    }

    private func quarantineAndRemove(
        named name: String,
        beneath parentDescriptor: Int32,
        expectedIdentity: FileIdentity,
        beforeFinalMutation: ExternalDataConsentStoreHooks.OperationHook
    ) throws {
        let quarantine = try moveToQuarantine(
            named: name,
            beneath: parentDescriptor,
            expectedIdentity: expectedIdentity,
            beforeFinalMutation: beforeFinalMutation
        )
        try removeQuarantinedEntry(quarantine, beneath: parentDescriptor)
    }

    private func quarantineCurrentWithoutDeleting(beneath parentDescriptor: Int32) throws {
        guard try entryMetadata(named: receiptName, beneath: parentDescriptor) != nil else {
            return
        }
        for _ in 0..<32 {
            let quarantineName = ".\(receiptName).\(UUID().uuidString).quarantine"
            let status = exclusiveRename(receiptName, quarantineName, beneath: parentDescriptor)
            if status == 0 {
                try synchronize(parentDescriptor)
                return
            }
            let code = errno
            if code == EEXIST { continue }
            if code == ENOENT { return }
            if code == ELOOP {
                throw ExternalDataConsentStoreError.insecureFilesystemState
            }
            throw ExternalDataConsentStoreError.filesystemOperationFailed(code)
        }
        throw ExternalDataConsentStoreError.insecureFilesystemState
    }

    private func recoverFailedSwap(
        temporaryName: String,
        expectedExistingIdentity: FileIdentity,
        beneath parentDescriptor: Int32
    ) {
        do {
            try swapEntries(temporaryName, receiptName, beneath: parentDescriptor)
            try synchronize(parentDescriptor)
        } catch {
            // The caller still verifies the current name and quarantines anything unexpected.
        }
        guard entryIdentity(named: receiptName, beneath: parentDescriptor) != expectedExistingIdentity else {
            return
        }
        try? quarantineCurrentWithoutDeleting(beneath: parentDescriptor)
    }

    private func entryMetadata(named name: String, beneath parentDescriptor: Int32) throws -> stat? {
        var metadata = stat()
        let status = name.withCString { component in
            fstatat(parentDescriptor, component, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
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
                    throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
                }
                written += count
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        let maximumReceiptSize = 16 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
            }
            guard data.count + count <= maximumReceiptSize else {
                throw ExternalDataConsentStoreError.invalidReceiptEncoding
            }
            data.append(buffer, count: count)
        }
    }

    private func encodeReceipt(_ receipt: ExternalDataConsentReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(receipt)
        } catch {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
    }

    private func decodeReceipt(_ data: Data) throws -> ExternalDataConsentReceipt {
        do {
            var memberScanner = JSONTopLevelMemberScanner(data: data)
            let serializedMemberNames = try memberScanner.uniqueMemberNames()
            guard try JSONSerialization.jsonObject(with: data) is [String: Any],
                  serializedMemberNames == Set([
                      "schema_version",
                      "policy_version",
                      "accepted_at",
                      "external_provider_risk_accepted",
                      "document_tool_access_accepted"
                  ])
            else {
                throw ExternalDataConsentStoreError.invalidReceiptEncoding
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ExternalDataConsentReceipt.self, from: data)
        } catch let error as ExternalDataConsentStoreError {
            throw error
        } catch {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
    }

    private func close(_ handles: [DirectoryHandle]) {
        for handle in handles.reversed() {
            Darwin.close(handle.descriptor)
        }
    }

    private func identity(of metadata: stat) -> FileIdentity {
        FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & S_IFMT
    }

    private func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty &&
            component != "." &&
            component != ".." &&
            !component.contains("/") &&
            !component.contains("\0")
    }
}

private struct JSONTopLevelMemberScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func uniqueMemberNames() throws -> Set<String> {
        skipWhitespace()
        try consume(ascii: "{")
        skipWhitespace()
        var names: Set<String> = []
        if consumeIfPresent(ascii: "}") {
            try requireEnd()
            return names
        }

        while true {
            let memberName = try parseString()
            guard names.insert(memberName).inserted else {
                throw ExternalDataConsentStoreError.invalidReceiptEncoding
            }
            skipWhitespace()
            try consume(ascii: ":")
            try skipValue(depth: 0)
            skipWhitespace()
            if consumeIfPresent(ascii: "}") {
                try requireEnd()
                return names
            }
            try consume(ascii: ",")
            skipWhitespace()
        }
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth <= 64 else {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
        skipWhitespace()
        guard let byte = currentByte else {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
        switch byte {
        case ascii("\""):
            _ = try parseString()
        case ascii("{"):
            try skipObject(depth: depth + 1)
        case ascii("["):
            try skipArray(depth: depth + 1)
        default:
            let start = index
            while let byte = currentByte,
                  !isWhitespace(byte),
                  byte != ascii(","),
                  byte != ascii("}"),
                  byte != ascii("]")
            {
                index += 1
            }
            guard index > start else {
                throw ExternalDataConsentStoreError.invalidReceiptEncoding
            }
        }
    }

    private mutating func skipObject(depth: Int) throws {
        try consume(ascii: "{")
        skipWhitespace()
        if consumeIfPresent(ascii: "}") { return }
        while true {
            _ = try parseString()
            skipWhitespace()
            try consume(ascii: ":")
            try skipValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(ascii: "}") { return }
            try consume(ascii: ",")
            skipWhitespace()
        }
    }

    private mutating func skipArray(depth: Int) throws {
        try consume(ascii: "[")
        skipWhitespace()
        if consumeIfPresent(ascii: "]") { return }
        while true {
            try skipValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(ascii: "]") { return }
            try consume(ascii: ",")
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        skipWhitespace()
        let start = index
        try consume(ascii: "\"")
        var escaped = false
        while let byte = currentByte {
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == ascii("\\") {
                escaped = true
                continue
            }
            if byte == ascii("\"") {
                let token = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: token)
                } catch {
                    throw ExternalDataConsentStoreError.invalidReceiptEncoding
                }
            }
        }
        throw ExternalDataConsentStoreError.invalidReceiptEncoding
    }

    private mutating func requireEnd() throws {
        skipWhitespace()
        guard index == bytes.count else {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
    }

    private mutating func consume(ascii character: Character) throws {
        guard consumeIfPresent(ascii: character) else {
            throw ExternalDataConsentStoreError.invalidReceiptEncoding
        }
    }

    private mutating func consumeIfPresent(ascii character: Character) -> Bool {
        let expected = ascii(character)
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, isWhitespace(byte) {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}

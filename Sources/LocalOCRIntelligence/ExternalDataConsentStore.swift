import Darwin
import Foundation

public enum ExternalDataConsentStoreError: Error, Sendable {
    case invalidReceiptPath
    case missingPath
    case insecureFilesystemState
    case filesystemOperationFailed(Int32)
    case invalidReceiptEncoding
}

public actor ExternalDataConsentStore: ExternalDataConsentStoring {
    private typealias OperationHook = @Sendable () throws -> Void

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
    private let beforeAcceptRename: OperationHook
    private let beforeRevokeUnlink: OperationHook

    public init(receiptURL: URL = ExternalDataConsentStore.defaultReceiptURL) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        beforeAcceptRename = {}
        beforeRevokeUnlink = {}
    }

    init(receiptURL: URL, expectedReceiptOwnerID: uid_t) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        self.expectedReceiptOwnerID = expectedReceiptOwnerID
        beforeAcceptRename = {}
        beforeRevokeUnlink = {}
    }

    init(
        receiptURL: URL,
        beforeAcceptRename: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        self.beforeAcceptRename = beforeAcceptRename
        beforeRevokeUnlink = {}
    }

    init(
        receiptURL: URL,
        beforeRevokeUnlink: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptName = receiptURL.lastPathComponent
        directoryComponents = Array(receiptURL.pathComponents.dropFirst().dropLast())
        expectedReceiptOwnerID = geteuid()
        beforeAcceptRename = {}
        self.beforeRevokeUnlink = beforeRevokeUnlink
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
        try validateExistingReceiptForMutation(beneath: parent.descriptor)

        let temporary = try createTemporaryReceipt(beneath: parent.descriptor)
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary.descriptor)
            if shouldRemoveTemporary {
                removeEntryIfItMatches(
                    named: temporary.name,
                    beneath: parent.descriptor,
                    identity: temporary.identity
                )
            }
        }

        try writeAll(data, to: temporary.descriptor)
        guard fsync(temporary.descriptor) == 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }

        try beforeAcceptRename()
        try reprove(handles)
        try validateExistingReceiptForMutation(beneath: parent.descriptor)
        try requireEntry(
            named: temporary.name,
            beneath: parent.descriptor,
            matches: temporary.identity
        )
        let renameStatus = temporary.name.withCString { temporaryName in
            receiptName.withCString { finalName in
                renameat(parent.descriptor, temporaryName, parent.descriptor, finalName)
            }
        }
        guard renameStatus == 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }
        shouldRemoveTemporary = false
        try requireEntry(
            named: receiptName,
            beneath: parent.descriptor,
            matches: temporary.identity
        )
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

        try beforeRevokeUnlink()
        try reprove(handles)
        try requireEntry(
            named: receiptName,
            beneath: parent.descriptor,
            matches: openedReceipt.identity
        )
        let unlinkStatus = receiptName.withCString { name in
            unlinkat(parent.descriptor, name, 0)
        }
        guard unlinkStatus == 0 else {
            throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
        }
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
                if wasCreated {
                    guard fchmod(child.descriptor, 0o700) == 0 else {
                        Darwin.close(child.descriptor)
                        throw ExternalDataConsentStoreError.filesystemOperationFailed(errno)
                    }
                }
                if isApplicationDirectory {
                    try requirePrivateApplicationDirectory(child)
                }
                handles.append(child)
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
              metadata.st_mode & 0o777 == 0o700
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

    private func validateExistingReceiptForMutation(beneath parentDescriptor: Int32) throws {
        guard let metadata = try entryMetadata(named: receiptName, beneath: parentDescriptor) else {
            return
        }
        try validateReceiptMetadata(metadata)
    }

    private func validateReceiptMetadata(_ metadata: stat) throws {
        guard fileType(metadata) == S_IFREG,
              metadata.st_uid == expectedReceiptOwnerID,
              metadata.st_mode & 0o777 == 0o600
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
                      metadata.st_mode & 0o777 == 0o600
                else {
                    throw ExternalDataConsentStoreError.insecureFilesystemState
                }
                return (descriptor, name, identity(of: metadata))
            } catch {
                Darwin.close(descriptor)
                _ = name.withCString { unlinkat(parentDescriptor, $0, 0) }
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

    private func removeEntryIfItMatches(
        named name: String,
        beneath parentDescriptor: Int32,
        identity expectedIdentity: FileIdentity
    ) {
        guard let metadata = try? entryMetadata(named: name, beneath: parentDescriptor),
              fileType(metadata) == S_IFREG,
              identity(of: metadata) == expectedIdentity
        else {
            return
        }
        _ = name.withCString { unlinkat(parentDescriptor, $0, 0) }
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
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set([
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

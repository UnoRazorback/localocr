#!/usr/bin/swift

import Darwin
import Foundation

@_silgen_name("removefileat")
private func removeFileAt(
    _ descriptor: Int32,
    _ path: UnsafePointer<CChar>,
    _ state: OpaquePointer?,
    _ flags: UInt32
) -> Int32

private let removeFileRecursive = UInt32(1 << 0)
private let removeFileKeepParent = UInt32(1 << 1)

private struct Identity: Equatable {
    let parentDevice: UInt64
    let parentInode: UInt64
    let fileDevice: UInt64
    let fileInode: UInt64

    var token: String {
        [parentDevice, parentInode, fileDevice, fileInode]
            .map(String.init)
            .joined(separator: ":")
    }

    init(parent: stat, file: stat) {
        parentDevice = UInt64(parent.st_dev)
        parentInode = UInt64(parent.st_ino)
        fileDevice = UInt64(file.st_dev)
        fileInode = UInt64(file.st_ino)
    }

    init?(token: String) {
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4,
              let parentDevice = UInt64(fields[0]),
              let parentInode = UInt64(fields[1]),
              let fileDevice = UInt64(fields[2]),
              let fileInode = UInt64(fields[3])
        else {
            return nil
        }
        self.parentDevice = parentDevice
        self.parentInode = parentInode
        self.fileDevice = fileDevice
        self.fileInode = fileInode
    }
}

private struct DirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    var token: String {
        "\(device):\(inode)"
    }

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init?(token: String) {
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let device = UInt64(fields[0]),
              let inode = UInt64(fields[1])
        else {
            return nil
        }
        self.device = device
        self.inode = inode
    }
}

private struct OpenedFile {
    let parentFD: Int32
    let fileFD: Int32
    let parentPath: String
    let name: String
    let parentStat: stat
    let fileStat: stat

    var identity: Identity {
        Identity(parent: parentStat, file: fileStat)
    }

    func closeAll() {
        close(fileFD)
        close(parentFD)
    }
}

private enum ExpectedDirectory {
    case missing
    case existing(DirectoryIdentity)
}

private enum GuardError: Error, CustomStringConvertible {
    case invalid(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

private func requireAbsoluteStandardPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("/"),
          !path.hasSuffix("/"),
          components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !(path as NSString).lastPathComponent.isEmpty
    else {
        throw GuardError.invalid("path guard requires an absolute standardized path")
    }
}

private func sameObject(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
}

private func isRegularFile(_ value: stat) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
}

private func isDirectory(_ value: stat) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
}

private func physicalPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else {
        throw GuardError.system("realpath", errno)
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func directoryIdentity(_ path: String) throws -> DirectoryIdentity {
    try requireAbsoluteStandardPath(path)
    guard try physicalPath(path) == path else {
        throw GuardError.invalid("path guard directory is not physical")
    }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
        throw GuardError.system("open directory", errno)
    }
    defer { close(fd) }
    var descriptorStat = stat()
    var namedStat = stat()
    guard fstat(fd, &descriptorStat) == 0,
          lstat(path, &namedStat) == 0,
          sameObject(descriptorStat, namedStat)
    else {
        throw GuardError.system("verify directory identity", errno)
    }
    return DirectoryIdentity(
        device: UInt64(descriptorStat.st_dev),
        inode: UInt64(descriptorStat.st_ino)
    )
}

private func publishDirectory(
    candidate: String,
    target: String,
    expectedParent: DirectoryIdentity,
    expectedCandidate: DirectoryIdentity,
    expectedTarget: ExpectedDirectory
) throws -> Bool {
    try requireAbsoluteStandardPath(candidate)
    try requireAbsoluteStandardPath(target)
    let parentPath = (target as NSString).deletingLastPathComponent
    let candidateParent = (candidate as NSString).deletingLastPathComponent
    let candidateName = (candidate as NSString).lastPathComponent
    let targetName = (target as NSString).lastPathComponent
    guard candidateParent == parentPath,
          candidateName != targetName,
          !candidateName.contains("/"),
          !targetName.contains("/")
    else {
        throw GuardError.invalid("directory publication requires distinct sibling paths")
    }
    guard try physicalPath(parentPath) == parentPath else {
        throw GuardError.invalid("directory publication parent is not physical")
    }

    let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else {
        throw GuardError.system("open directory publication parent", errno)
    }
    defer { close(parentFD) }
    var parentStat = stat()
    var namedParentStat = stat()
    guard fstat(parentFD, &parentStat) == 0,
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat),
          DirectoryIdentity(
              device: UInt64(parentStat.st_dev),
              inode: UInt64(parentStat.st_ino)
          ) == expectedParent
    else {
        throw GuardError.invalid("directory publication parent identity changed")
    }

    let candidateFD = openat(
        parentFD,
        candidateName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard candidateFD >= 0 else {
        throw GuardError.system("open directory publication candidate", errno)
    }
    defer { close(candidateFD) }
    var candidateStat = stat()
    var namedCandidateStat = stat()
    guard fstat(candidateFD, &candidateStat) == 0,
          fstatat(
              parentFD,
              candidateName,
              &namedCandidateStat,
              AT_SYMLINK_NOFOLLOW
          ) == 0,
          sameObject(candidateStat, namedCandidateStat),
          DirectoryIdentity(
              device: UInt64(candidateStat.st_dev),
              inode: UInt64(candidateStat.st_ino)
          ) == expectedCandidate
    else {
        throw GuardError.invalid("directory publication candidate identity changed")
    }

    var existingTargetStat = stat()
    let targetStatus = fstatat(
        parentFD,
        targetName,
        &existingTargetStat,
        AT_SYMLINK_NOFOLLOW
    )
    var targetStatAtExchange = stat()
    let exchanged: Bool
    switch expectedTarget {
    case .existing(let expectedTargetIdentity):
        guard targetStatus == 0,
              (existingTargetStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              DirectoryIdentity(
                  device: UInt64(existingTargetStat.st_dev),
                  inode: UInt64(existingTargetStat.st_ino)
              ) == expectedTargetIdentity
        else {
            throw GuardError.invalid("existing directory publication target is invalid")
        }
        let targetFD = openat(
            parentFD,
            targetName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard targetFD >= 0 else {
            throw GuardError.system("open directory publication target", errno)
        }
        defer { close(targetFD) }
        var descriptorTargetStat = stat()
        guard fstat(targetFD, &descriptorTargetStat) == 0,
              sameObject(descriptorTargetStat, existingTargetStat),
              lstat(parentPath, &namedParentStat) == 0,
              sameObject(parentStat, namedParentStat)
        else {
            throw GuardError.invalid("directory publication target identity changed")
        }
        targetStatAtExchange = descriptorTargetStat
        guard renameatx_np(
            parentFD,
            candidateName,
            parentFD,
            targetName,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw GuardError.system("exchange published directory", errno)
        }
        exchanged = true
    case .missing:
        guard targetStatus != 0, errno == ENOENT,
              lstat(parentPath, &namedParentStat) == 0,
              sameObject(parentStat, namedParentStat)
        else {
            throw GuardError.invalid("missing directory publication target appeared")
        }
        guard renameatx_np(
            parentFD,
            candidateName,
            parentFD,
            targetName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw GuardError.system("publish directory", errno)
        }
        exchanged = false
    }

    var publishedStat = stat()
    var displacedTargetStat = stat()
    let displacedTargetStatus = fstatat(
        parentFD,
        candidateName,
        &displacedTargetStat,
        AT_SYMLINK_NOFOLLOW
    )
    let displacedTargetError = errno
    let displacedTargetIsExpected = exchanged
        ? displacedTargetStatus == 0
            && sameObject(targetStatAtExchange, displacedTargetStat)
        : displacedTargetStatus != 0 && displacedTargetError == ENOENT
    guard fstatat(
              parentFD,
              targetName,
              &publishedStat,
              AT_SYMLINK_NOFOLLOW
          ) == 0,
          sameObject(candidateStat, publishedStat),
          displacedTargetIsExpected,
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat)
    else {
        if exchanged {
            _ = renameatx_np(
                parentFD,
                candidateName,
                parentFD,
                targetName,
                UInt32(RENAME_SWAP)
            )
        } else {
            _ = renameatx_np(
                parentFD,
                targetName,
                parentFD,
                candidateName,
                UInt32(RENAME_EXCL)
            )
        }
        throw GuardError.invalid("published directory identity changed during commit")
    }
    return exchanged
}

private func unusedCleanupName(parentFD: Int32) throws -> String {
    for _ in 0..<64 {
        let name = ".localocr-cleanup.\(getpid()).\(UUID().uuidString)"
        var metadata = stat()
        let status = name.withCString { candidate in
            fstatat(parentFD, candidate, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0, errno == ENOENT {
            return name
        }
        if status != 0 {
            throw GuardError.system("inspect private cleanup name", errno)
        }
    }
    throw GuardError.invalid("could not allocate a private cleanup name")
}

private func restoreQuarantinedDirectory(
    parentFD: Int32,
    quarantineName: String,
    publicName: String
) {
    _ = quarantineName.withCString { quarantine in
        publicName.withCString { target in
            renameatx_np(
                parentFD,
                quarantine,
                parentFD,
                target,
                UInt32(RENAME_EXCL)
            )
        }
    }
}

private func cleanupDirectory(
    path: String,
    expectedParent: DirectoryIdentity,
    expectedDirectory: DirectoryIdentity
) throws {
    try requireAbsoluteStandardPath(path)
    let parentPath = (path as NSString).deletingLastPathComponent
    let directoryName = (path as NSString).lastPathComponent
    guard !directoryName.isEmpty,
          directoryName != ".",
          directoryName != "..",
          !directoryName.contains("/")
    else {
        throw GuardError.invalid("directory cleanup requires one safe leaf name")
    }
    guard try physicalPath(parentPath) == parentPath else {
        throw GuardError.invalid("directory cleanup parent is not physical")
    }

    let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else {
        throw GuardError.system("open directory cleanup parent", errno)
    }
    defer { close(parentFD) }

    var parentStat = stat()
    var namedParentStat = stat()
    guard fstat(parentFD, &parentStat) == 0,
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat),
          DirectoryIdentity(
              device: UInt64(parentStat.st_dev),
              inode: UInt64(parentStat.st_ino)
          ) == expectedParent
    else {
        throw GuardError.invalid("directory cleanup parent identity changed")
    }

    let directoryFD = directoryName.withCString { name in
        openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard directoryFD >= 0 else {
        throw GuardError.system("open directory cleanup target", errno)
    }
    defer { close(directoryFD) }

    var directoryStat = stat()
    var namedDirectoryStat = stat()
    guard fstat(directoryFD, &directoryStat) == 0,
          isDirectory(directoryStat),
          directoryName.withCString({ name in
              fstatat(parentFD, name, &namedDirectoryStat, AT_SYMLINK_NOFOLLOW)
          }) == 0,
          sameObject(directoryStat, namedDirectoryStat),
          DirectoryIdentity(
              device: UInt64(directoryStat.st_dev),
              inode: UInt64(directoryStat.st_ino)
          ) == expectedDirectory
    else {
        throw GuardError.invalid("directory cleanup target identity changed")
    }

    let quarantineName = try unusedCleanupName(parentFD: parentFD)
    var previousSignals = try blockCommitTerminationSignals()
    defer { restoreCommitTerminationSignals(&previousSignals) }
    guard lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat),
          directoryName.withCString({ name in
              fstatat(parentFD, name, &namedDirectoryStat, AT_SYMLINK_NOFOLLOW)
          }) == 0,
          sameObject(directoryStat, namedDirectoryStat),
          try !commitTerminationSignalIsPending()
    else {
        throw GuardError.invalid("directory cleanup target changed or cleanup was interrupted")
    }

    // The checked public leaf is quarantined through the anchored parent descriptor.
    let renameStatus = directoryName.withCString { publicName in
        quarantineName.withCString { quarantine in
            renameatx_np(
                parentFD,
                publicName,
                parentFD,
                quarantine,
                UInt32(RENAME_EXCL)
            )
        }
    }
    guard renameStatus == 0 else {
        throw GuardError.system("quarantine directory for cleanup", errno)
    }

    var quarantinedStat = stat()
    var publicStat = stat()
    let quarantineStatus = quarantineName.withCString { name in
        fstatat(parentFD, name, &quarantinedStat, AT_SYMLINK_NOFOLLOW)
    }
    let publicStatus = directoryName.withCString { name in
        fstatat(parentFD, name, &publicStat, AT_SYMLINK_NOFOLLOW)
    }
    let publicError = errno
    guard quarantineStatus == 0,
          sameObject(directoryStat, quarantinedStat),
          publicStatus != 0,
          publicError == ENOENT,
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat)
    else {
        restoreQuarantinedDirectory(
            parentFD: parentFD,
            quarantineName: quarantineName,
            publicName: directoryName
        )
        throw GuardError.invalid("quarantined directory identity changed")
    }
    guard try !commitTerminationSignalIsPending() else {
        throw GuardError.invalid("directory cleanup was interrupted after quarantine")
    }

    let removalStatus = ".".withCString { currentDirectory in
        removeFileAt(
            directoryFD,
            currentDirectory,
            nil,
            removeFileRecursive | removeFileKeepParent
        )
    }
    guard removalStatus == 0 else {
        throw GuardError.system("remove quarantined directory contents", errno)
    }

    guard fstat(directoryFD, &namedDirectoryStat) == 0,
          sameObject(directoryStat, namedDirectoryStat),
          quarantineName.withCString({ name in
              fstatat(parentFD, name, &quarantinedStat, AT_SYMLINK_NOFOLLOW)
          }) == 0,
          sameObject(directoryStat, quarantinedStat),
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat)
    else {
        throw GuardError.invalid("private cleanup quarantine changed before removal")
    }
    let unlinkStatus = quarantineName.withCString { name in
        unlinkat(parentFD, name, AT_REMOVEDIR)
    }
    guard unlinkStatus == 0 else {
        throw GuardError.system("remove private cleanup quarantine", errno)
    }
    guard fsync(parentFD) == 0 else {
        throw GuardError.system("sync directory cleanup parent", errno)
    }
}

private func openExactFile(_ path: String) throws -> OpenedFile {
    try requireAbsoluteStandardPath(path)
    let parentPath = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    guard try physicalPath(parentPath) == parentPath else {
        throw GuardError.invalid("path guard parent is not physical")
    }

    let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else {
        throw GuardError.system("open parent", errno)
    }
    var parentStat = stat()
    guard fstat(parentFD, &parentStat) == 0 else {
        let code = errno
        close(parentFD)
        throw GuardError.system("fstat parent", code)
    }
    var namedParentStat = stat()
    guard lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat)
    else {
        let code = errno
        close(parentFD)
        throw GuardError.system("verify parent identity", code)
    }

    let fileFD = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fileFD >= 0 else {
        let code = errno
        close(parentFD)
        throw GuardError.system("open file", code)
    }
    var fileStat = stat()
    var namedFileStat = stat()
    guard fstat(fileFD, &fileStat) == 0,
          isRegularFile(fileStat),
          fstatat(parentFD, name, &namedFileStat, AT_SYMLINK_NOFOLLOW) == 0,
          sameObject(fileStat, namedFileStat)
    else {
        let code = errno
        close(fileFD)
        close(parentFD)
        throw GuardError.system("verify file identity", code)
    }
    return OpenedFile(
        parentFD: parentFD,
        fileFD: fileFD,
        parentPath: parentPath,
        name: name,
        parentStat: parentStat,
        fileStat: fileStat
    )
}

private func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
    var written = 0
    while written < count {
        let result = Darwin.write(fd, bytes.advanced(by: written), count - written)
        guard result > 0 else {
            throw GuardError.system("write", errno)
        }
        written += result
    }
}

private func copyBytes(from sourceFD: Int32, to destinationFD: Int32) throws {
    guard lseek(sourceFD, 0, SEEK_SET) >= 0,
          lseek(destinationFD, 0, SEEK_SET) >= 0
    else {
        throw GuardError.system("seek", errno)
    }
    var buffer = [UInt8](repeating: 0, count: 128 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard count >= 0 else {
            throw GuardError.system("read", errno)
        }
        if count == 0 {
            break
        }
        try buffer.withUnsafeBytes { rawBuffer in
            try writeAll(destinationFD, bytes: rawBuffer.baseAddress!, count: count)
        }
    }
}

private func snapshotFile(source: String, destination: String) throws -> Identity {
    let openedSource = try openExactFile(source)
    defer { openedSource.closeAll() }

    try requireAbsoluteStandardPath(destination)
    let destinationParent = (destination as NSString).deletingLastPathComponent
    let destinationName = (destination as NSString).lastPathComponent
    guard try physicalPath(destinationParent) == destinationParent else {
        throw GuardError.invalid("snapshot destination parent is not physical")
    }
    let destinationParentFD = open(
        destinationParent,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard destinationParentFD >= 0 else {
        throw GuardError.system("open snapshot parent", errno)
    }
    defer { close(destinationParentFD) }
    let mode = openedSource.fileStat.st_mode & mode_t(0o777)
    let destinationFD = openat(
        destinationParentFD,
        destinationName,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode
    )
    guard destinationFD >= 0 else {
        throw GuardError.system("create snapshot", errno)
    }
    defer { close(destinationFD) }
    try copyBytes(from: openedSource.fileFD, to: destinationFD)
    guard fsync(destinationFD) == 0 else {
        throw GuardError.system("fsync snapshot", errno)
    }
    return openedSource.identity
}

private func pathStillReferencesParent(_ opened: OpenedFile) -> Bool {
    var current = stat()
    return lstat(opened.parentPath, &current) == 0
        && sameObject(opened.parentStat, current)
}

private func nameStillReferencesFile(_ opened: OpenedFile) -> Bool {
    var current = stat()
    return fstatat(opened.parentFD, opened.name, &current, AT_SYMLINK_NOFOLLOW) == 0
        && sameObject(opened.fileStat, current)
}

private let commitTerminationSignals = [SIGHUP, SIGINT, SIGTERM]

private func blockCommitTerminationSignals() throws -> sigset_t {
    var blockedSignals = sigset_t()
    guard sigemptyset(&blockedSignals) == 0 else {
        throw GuardError.system("initialize commit signal mask", errno)
    }
    for signalNumber in commitTerminationSignals {
        guard sigaddset(&blockedSignals, signalNumber) == 0 else {
            throw GuardError.system("add commit signal", errno)
        }
    }
    var previousSignals = sigset_t()
    let status = pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals)
    guard status == 0 else {
        throw GuardError.system("block commit signals", status)
    }
    return previousSignals
}

private func restoreCommitTerminationSignals(_ previousSignals: inout sigset_t) {
    _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil)
}

private func commitTerminationSignalIsPending() throws -> Bool {
    var pendingSignals = sigset_t()
    guard sigpending(&pendingSignals) == 0 else {
        throw GuardError.system("inspect pending commit signals", errno)
    }
    return commitTerminationSignals.contains {
        sigismember(&pendingSignals, $0) == 1
    }
}

private func createCommitSibling(
    parentFD: Int32,
    mode: mode_t
) throws -> (name: String, fd: Int32) {
    for _ in 0..<64 {
        let name = ".localocr-commit.\(getpid()).\(UUID().uuidString)"
        let fd = openat(
            parentFD,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        if fd >= 0 {
            return (name, fd)
        }
        guard errno == EEXIST else {
            throw GuardError.system("create private commit sibling", errno)
        }
    }
    throw GuardError.invalid("could not allocate a private commit sibling")
}

private func namedObject(
    parentFD: Int32,
    name: String,
    matches expected: stat
) -> Bool {
    var current = stat()
    return fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0
        && sameObject(current, expected)
}

private func rollbackFileExchange(
    parentFD: Int32,
    candidateName: String,
    targetName: String
) -> Bool {
    renameatx_np(
        parentFD,
        candidateName,
        parentFD,
        targetName,
        UInt32(RENAME_SWAP)
    ) == 0
}

private func commitFile(
    source: String,
    target: String,
    expectedTarget: Identity,
    expectedSource: Identity
) throws {
    let openedSource = try openExactFile(source)
    defer { openedSource.closeAll() }
    guard openedSource.identity == expectedSource else {
        throw GuardError.invalid("sanitized source identity changed before commit")
    }
    let openedTarget = try openExactFile(target)
    defer { openedTarget.closeAll() }
    guard openedTarget.identity == expectedTarget else {
        throw GuardError.invalid("release target identity changed before commit")
    }

    var previousSignals = try blockCommitTerminationSignals()
    defer { restoreCommitTerminationSignals(&previousSignals) }
    var commitSiblingName: String?
    var commitSiblingFD: Int32 = -1
    var exchangeCompleted = false

    do {
        let sibling = try createCommitSibling(
            parentFD: openedTarget.parentFD,
            mode: openedSource.fileStat.st_mode & mode_t(0o777)
        )
        commitSiblingName = sibling.name
        commitSiblingFD = sibling.fd
        defer { close(commitSiblingFD) }

        try copyBytes(from: openedSource.fileFD, to: commitSiblingFD)
        guard fchmod(
                  commitSiblingFD,
                  openedSource.fileStat.st_mode & mode_t(0o777)
              ) == 0,
              fsync(commitSiblingFD) == 0
        else {
            throw GuardError.system("finalize private commit sibling", errno)
        }
        var siblingStat = stat()
        let interruptedBeforePublication = try commitTerminationSignalIsPending()
        guard fstat(commitSiblingFD, &siblingStat) == 0,
              namedObject(
                  parentFD: openedTarget.parentFD,
                  name: sibling.name,
                  matches: siblingStat
              ),
              pathStillReferencesParent(openedTarget),
              nameStillReferencesFile(openedTarget),
              !interruptedBeforePublication
        else {
            throw GuardError.invalid("release target changed or commit was interrupted")
        }
        guard fsync(openedTarget.parentFD) == 0 else {
            throw GuardError.system("sync commit parent before publication", errno)
        }
        guard renameatx_np(
            openedTarget.parentFD,
            sibling.name,
            openedTarget.parentFD,
            openedTarget.name,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw GuardError.system("atomically publish committed file", errno)
        }
        exchangeCompleted = true

        let interruptedDuringPublication = try commitTerminationSignalIsPending()
        guard namedObject(
                  parentFD: openedTarget.parentFD,
                  name: openedTarget.name,
                  matches: siblingStat
              ),
              namedObject(
                  parentFD: openedTarget.parentFD,
                  name: sibling.name,
                  matches: openedTarget.fileStat
              ),
              pathStillReferencesParent(openedTarget),
              !interruptedDuringPublication,
              fsync(openedTarget.parentFD) == 0
        else {
            guard rollbackFileExchange(
                parentFD: openedTarget.parentFD,
                candidateName: sibling.name,
                targetName: openedTarget.name
            ) else {
                throw GuardError.invalid("could not roll back interrupted file publication")
            }
            exchangeCompleted = false
            throw GuardError.invalid("file publication changed or was interrupted")
        }
        guard unlinkat(openedTarget.parentFD, sibling.name, 0) == 0 else {
            let unlinkError = errno
            guard rollbackFileExchange(
                parentFD: openedTarget.parentFD,
                candidateName: sibling.name,
                targetName: openedTarget.name
            ) else {
                throw GuardError.invalid("could not roll back incomplete file cleanup")
            }
            exchangeCompleted = false
            throw GuardError.system("remove replaced release target", unlinkError)
        }
        commitSiblingName = nil
        _ = fsync(openedTarget.parentFD)
    } catch {
        if exchangeCompleted, let siblingName = commitSiblingName {
            if rollbackFileExchange(
                parentFD: openedTarget.parentFD,
                candidateName: siblingName,
                targetName: openedTarget.name
            ) {
                exchangeCompleted = false
            }
        }
        if !exchangeCompleted, let siblingName = commitSiblingName {
            if unlinkat(openedTarget.parentFD, siblingName, 0) != 0,
               errno != ENOENT
            {
                throw GuardError.system("clean private commit sibling", errno)
            }
        }
        throw error
    }
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw GuardError.invalid("usage: release-path-guard.swift MODE ...")
    }
    switch arguments[1] {
    case "token-directory":
        guard arguments.count == 3 else {
            throw GuardError.invalid("token-directory requires one path")
        }
        print(try directoryIdentity(arguments[2]).token)
    case "token-file":
        guard arguments.count == 3 else {
            throw GuardError.invalid("token-file requires one path")
        }
        let opened = try openExactFile(arguments[2])
        defer { opened.closeAll() }
        print(opened.identity.token)
    case "snapshot-file":
        guard arguments.count == 4 else {
            throw GuardError.invalid("snapshot-file requires source and destination")
        }
        print(try snapshotFile(source: arguments[2], destination: arguments[3]).token)
    case "commit-file":
        guard arguments.count == 6,
              let expectedTarget = Identity(token: arguments[4]),
              let expectedSource = Identity(token: arguments[5])
        else {
            throw GuardError.invalid("commit-file requires source, target, and two identities")
        }
        try commitFile(
            source: arguments[2],
            target: arguments[3],
            expectedTarget: expectedTarget,
            expectedSource: expectedSource
        )
    case "publish-directory":
        guard arguments.count == 7,
              let expectedParent = DirectoryIdentity(token: arguments[4]),
              let expectedCandidate = DirectoryIdentity(token: arguments[5])
        else {
            throw GuardError.invalid(
                "publish-directory requires paths and expected directory identities"
            )
        }
        let expectedTarget: ExpectedDirectory
        if arguments[6] == "missing" {
            expectedTarget = .missing
        } else if let identity = DirectoryIdentity(token: arguments[6]) {
            expectedTarget = .existing(identity)
        } else {
            throw GuardError.invalid("invalid expected directory target identity")
        }
        let exchanged = try publishDirectory(
            candidate: arguments[2],
            target: arguments[3],
            expectedParent: expectedParent,
            expectedCandidate: expectedCandidate,
            expectedTarget: expectedTarget
        )
        print(exchanged ? "exchanged" : "moved")
    case "cleanup-directory":
        guard arguments.count == 5,
              let expectedParent = DirectoryIdentity(token: arguments[3]),
              let expectedDirectory = DirectoryIdentity(token: arguments[4])
        else {
            throw GuardError.invalid(
                "cleanup-directory requires path and expected parent/directory identities"
            )
        }
        try cleanupDirectory(
            path: arguments[2],
            expectedParent: expectedParent,
            expectedDirectory: expectedDirectory
        )
    default:
        throw GuardError.invalid("unknown release path guard mode")
    }
}

do {
    try run()
} catch {
    fputs("release path guard: \(error)\n", stderr)
    exit(1)
}

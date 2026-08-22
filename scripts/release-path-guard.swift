#!/usr/bin/swift

import Darwin
import Foundation

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
    expectedParent: DirectoryIdentity
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
          sameObject(candidateStat, namedCandidateStat)
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
    let exchanged: Bool
    if targetStatus == 0 {
        guard (existingTargetStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw GuardError.invalid("existing directory publication target is invalid")
        }
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
    } else {
        guard errno == ENOENT else {
            throw GuardError.system("inspect directory publication target", errno)
        }
        guard renameat(parentFD, candidateName, parentFD, targetName) == 0 else {
            throw GuardError.system("publish directory", errno)
        }
        exchanged = false
    }

    var publishedStat = stat()
    guard fstatat(
              parentFD,
              targetName,
              &publishedStat,
              AT_SYMLINK_NOFOLLOW
          ) == 0,
          sameObject(candidateStat, publishedStat),
          lstat(parentPath, &namedParentStat) == 0,
          sameObject(parentStat, namedParentStat)
    else {
        throw GuardError.invalid("published directory identity changed during commit")
    }
    return exchanged
}

private func openExactFile(_ path: String, writable: Bool = false) throws -> OpenedFile {
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

    let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
    let fileFD = openat(parentFD, name, flags)
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
    let openedTarget = try openExactFile(target, writable: true)
    defer { openedTarget.closeAll() }
    guard openedTarget.identity == expectedTarget else {
        throw GuardError.invalid("release target identity changed before commit")
    }

    guard ftruncate(openedTarget.fileFD, 0) == 0 else {
        throw GuardError.system("truncate target", errno)
    }
    try copyBytes(from: openedSource.fileFD, to: openedTarget.fileFD)
    guard fchmod(openedTarget.fileFD, openedSource.fileStat.st_mode & mode_t(0o777)) == 0,
          fsync(openedTarget.fileFD) == 0
    else {
        throw GuardError.system("finalize target", errno)
    }
    guard pathStillReferencesParent(openedTarget),
          nameStillReferencesFile(openedTarget)
    else {
        throw GuardError.invalid("release target changed during commit")
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
        guard arguments.count == 5,
              let expectedParent = DirectoryIdentity(token: arguments[4])
        else {
            throw GuardError.invalid(
                "publish-directory requires candidate, target, and parent identity"
            )
        }
        let exchanged = try publishDirectory(
            candidate: arguments[2],
            target: arguments[3],
            expectedParent: expectedParent
        )
        print(exchanged ? "exchanged" : "moved")
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

import CryptoKit
import Darwin
import Foundation

public protocol LlamaCppProcessProbing: Sendable {
    func snapshot() async throws -> LlamaCppProcessSnapshot
}

public struct LlamaCppProcessSnapshot: Sendable, Equatable {
    public let alias: String
    public let modelPath: String
    public let fingerprint: String
    public let harnessVersion: String
    public let executablePath: String
    public let executableSHA256: String
    public let modelSize: Int64
    public let modelModifiedNanoseconds: Int64
    public let executableSize: Int64
    public let executableModifiedNanoseconds: Int64
    public let processID: Int32

    public init(alias: String, modelPath: String, fingerprint: String, harnessVersion: String,
                executablePath: String = "/fixture/llama-server", executableSHA256: String = "",
                modelSize: Int64 = 0, modelModifiedNanoseconds: Int64 = 0,
                executableSize: Int64 = 0, executableModifiedNanoseconds: Int64 = 0,
                processID: Int32 = 0) {
        self.alias = alias; self.modelPath = modelPath; self.fingerprint = fingerprint
        self.harnessVersion = harnessVersion; self.executablePath = executablePath
        self.executableSHA256 = executableSHA256; self.modelSize = modelSize
        self.modelModifiedNanoseconds = modelModifiedNanoseconds; self.executableSize = executableSize
        self.executableModifiedNanoseconds = executableModifiedNanoseconds; self.processID = processID
    }
}

public enum LlamaCppProcessProbeError: Error, Sendable {
    case unverified, unsafeArguments, unsafeFile, identityChanged, timedOut, outputTooLarge
}

/// No server lifecycle controls. Process metadata is inspected through Darwin and fixed system tools.
public struct LlamaCppProcessProbe: LlamaCppProcessProbing {
    private let cacheDirectory: URL
    public init() {
        cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalOCR/llama-cpp-hashes")
    }
    init(cacheDirectory: URL) { self.cacheDirectory = cacheDirectory }

    public func snapshot() async throws -> LlamaCppProcessSnapshot {
        try Task.checkCancellation()
        let pid = try Self.listenerPID(try await Self.command("/usr/sbin/lsof", ["-nP", "-iTCP:8080", "-sTCP:LISTEN", "-Fpn"]))
        let executable = try Self.executable(pid)
        let start = try Self.processStart(pid)
        let args = try Self.arguments(pid)
        let config = try Self.parseArguments(args.argv, environment: args.environment)
        let exe = try PinnedLocalFile(executable, executable: true)
        let model = try PinnedLocalFile(config.model, executable: false)
        guard exe.identity.changed <= start, model.identity.changed <= start else {
            throw LlamaCppProcessProbeError.identityChanged
        }
        let exeHash = try await cachedHash(exe)
        let modelHash = try await cachedHash(model)
        try exe.revalidate(); try model.revalidate()
        let versionData = try await LMStudioCommandRunner(
            commandTimeout: .seconds(5), terminationGracePeriod: .milliseconds(250),
            cleanupBudget: .seconds(1), pipeDrainBudget: .milliseconds(250),
            maximumOutputBytes: 16_384, captureStandardError: true
        ).run(executableDescriptor: exe.fd, displayPath: exe.path,
              arguments: ["--version"], environment: ["HOME=\(NSHomeDirectory())", "PATH="])
        let version = try Self.validVersion(versionData)
        try exe.revalidate(); try model.revalidate()
        guard try Self.processStart(pid) == start,
              try Self.executable(pid) == executable,
              try Self.arguments(pid) == args,
              try Self.listenerPID(try await Self.command("/usr/sbin/lsof", ["-nP", "-iTCP:8080", "-sTCP:LISTEN", "-Fpn"])) == pid else {
            throw LlamaCppProcessProbeError.identityChanged
        }
        return LlamaCppProcessSnapshot(alias: config.alias, modelPath: model.path,
            fingerprint: modelHash, harnessVersion: version, executablePath: exe.path,
            executableSHA256: exeHash, modelSize: model.identity.size,
            modelModifiedNanoseconds: model.identity.modified,
            executableSize: exe.identity.size, executableModifiedNanoseconds: exe.identity.modified,
            processID: pid)
    }

    struct Configuration: Equatable { let model: String; let alias: String; let host: String }
    static func parseArguments(_ argv: [String], environment: [String] = []) throws -> Configuration {
        guard argv.count > 1, argv.count < 128,
              !environment.contains(where: { $0.hasPrefix("LLAMA_") || $0.hasPrefix("GGML_RPC") || $0.hasPrefix("DYLD_") }) else {
            throw LlamaCppProcessProbeError.unsafeArguments
        }
        var values: [String: String] = [:]; var flags = Set<String>(); var i = 1
        let aliases = ["-m":"--model", "-a":"--alias", "-c":"--ctx-size", "-t":"--threads", "-ngl":"--gpu-layers"]
        let switches: Set<String> = ["--no-webui", "--jinja", "--no-mmap", "--mlock", "--no-mmproj", "--log-disable"]
        let numeric: Set<String> = ["--ctx-size", "--threads", "--threads-batch", "--gpu-layers", "--parallel", "--batch-size", "--ubatch-size"]
        while i < argv.count {
            let parts = argv[i].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = aliases[String(parts[0])] ?? String(parts[0])
            if switches.contains(key) {
                guard parts.count == 1, flags.insert(key).inserted else { throw LlamaCppProcessProbeError.unsafeArguments }
                i += 1; continue
            }
            guard ["--model", "--alias", "--host", "--port", "--reasoning"].contains(key) || numeric.contains(key), values[key] == nil else {
                throw LlamaCppProcessProbeError.unsafeArguments
            }
            let value: String
            if parts.count == 2 { value = String(parts[1]) } else {
                i += 1; guard i < argv.count else { throw LlamaCppProcessProbeError.unsafeArguments }; value = argv[i]
            }
            guard !value.isEmpty, value.utf8.count < 4096, !value.contains("\0") else { throw LlamaCppProcessProbeError.unsafeArguments }
            if numeric.contains(key) { guard let n = Int(value), n >= 0, n <= 1_048_576 else { throw LlamaCppProcessProbeError.unsafeArguments } }
            values[key] = value; i += 1
        }
        guard let model = values["--model"], model.hasPrefix("/"), URL(fileURLWithPath: model).pathExtension.lowercased() == "gguf",
              let host = values["--host"], ["127.0.0.1", "::1"].contains(host),
              values["--port"] == "8080", values["--reasoning"] == nil || values["--reasoning"] == "off" else {
            throw LlamaCppProcessProbeError.unsafeArguments
        }
        let alias = values["--alias"] ?? URL(fileURLWithPath: model).lastPathComponent
        guard alias.utf8.count <= 256, !alias.contains(","), !alias.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw LlamaCppProcessProbeError.unsafeArguments
        }
        return Configuration(model: model, alias: alias, host: host)
    }

    static func listenerPID(_ data: Data) throws -> Int32 {
        guard let text = String(data: data, encoding: .utf8) else { throw LlamaCppProcessProbeError.unverified }
        var pids = Set<Int32>(); var addresses = 0
        for line in text.split(separator: "\n") {
            if line.first == "p" {
                guard let pid = Int32(line.dropFirst()), pid > 0 else { throw LlamaCppProcessProbeError.unverified }; pids.insert(pid)
            } else if line.first == "n" {
                guard ["n127.0.0.1:8080", "n[::1]:8080"].contains(String(line)) else { throw LlamaCppProcessProbeError.unverified }; addresses += 1
            } else { throw LlamaCppProcessProbeError.unverified }
        }
        guard pids.count == 1, addresses > 0, let pid = pids.first else { throw LlamaCppProcessProbeError.unverified }
        return pid
    }

    static func validVersion(_ data: Data) throws -> String {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("version:") }),
              line.range(of: #"^version: [0-9]+ \([a-fA-F0-9]{7,40}\)$"#, options: .regularExpression) != nil else {
            throw LlamaCppProcessProbeError.unverified
        }
        return String(line)
    }

    private static func processStart(_ pid: Int32) throws -> Int64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else { throw LlamaCppProcessProbeError.unverified }
        return Int64(info.pbi_start_tvsec) * 1_000_000_000 + Int64(info.pbi_start_tvusec) * 1_000
    }

    private static func executable(_ pid: Int32) throws -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { throw LlamaCppProcessProbeError.unverified }
        return String(cString: buf)
    }
    private struct Arguments: Equatable { let argv: [String]; let environment: [String] }
    private static func arguments(_ pid: Int32) throws -> Arguments {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]; var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count > 4, count <= 1_048_576 else { throw LlamaCppProcessProbeError.unverified }
        var data = [UInt8](repeating: 0, count: count)
        guard sysctl(&mib, 3, &data, &count, nil, 0) == 0 else { throw LlamaCppProcessProbeError.unverified }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 128 else { throw LlamaCppProcessProbeError.unverified }
        var pos = 4
        func string() throws -> String {
            let start = pos
            while pos < count, data[pos] != 0 { pos += 1 }
            guard pos < count, let s = String(bytes: data[start..<pos], encoding: .utf8) else { throw LlamaCppProcessProbeError.unverified }
            pos += 1; return s
        }
        _ = try string() // kernel executable path, followed by alignment NULs
        while pos < count, data[pos] == 0 { pos += 1 }
        var argv: [String] = []
        for _ in 0..<argc { argv.append(try string()) }
        var env: [String] = []
        while pos < count, data[pos] != 0 { env.append(try string()) }
        return Arguments(argv: argv, environment: env)
    }

    func cachedHash(_ file: PinnedLocalFile) async throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(file.identity)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: cacheDirectory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard mkdir(cacheDirectory.path, 0o700) == 0 || errno == EEXIST else { throw LlamaCppProcessProbeError.unsafeFile }
        var ds = stat()
        guard lstat(cacheDirectory.path, &ds) == 0, ds.st_mode & S_IFMT == S_IFDIR, ds.st_uid == getuid(), ds.st_mode & 0o077 == 0,
              cacheDirectory.resolvingSymlinksInPath().path == cacheDirectory.standardizedFileURL.path else { throw LlamaCppProcessProbeError.unsafeFile }
        let url = cacheDirectory.appendingPathComponent(key + ".sha256")
        let dirFD = Darwin.open(cacheDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw LlamaCppProcessProbeError.unsafeFile }
        defer { Darwin.close(dirFD) }
        var openedDirectory = stat()
        guard fstat(dirFD, &openedDirectory) == 0, openedDirectory.st_dev == ds.st_dev,
              openedDirectory.st_ino == ds.st_ino else { throw LlamaCppProcessProbeError.unsafeFile }
        let fd = openat(dirFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { Darwin.close(fd) }; var st = stat(); var bytes = [UInt8](repeating: 0, count: 64)
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_size == 64,
                  Darwin.read(fd, &bytes, 64) == 64, let hash = String(bytes: bytes, encoding: .utf8), hash.allSatisfy({ $0.isHexDigit }) else { throw LlamaCppProcessProbeError.unsafeFile }
            try file.revalidate(); return hash
        }
        guard errno == ENOENT else { throw LlamaCppProcessProbeError.unsafeFile }
        var hasher = SHA256(); var offset: off_t = 0; var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let n = pread(file.fd, &buffer, buffer.count, offset)
            guard n >= 0 else { throw LlamaCppProcessProbeError.unsafeFile }
            if n == 0 { break }
            hasher.update(data: Data(buffer.prefix(n))); offset += off_t(n)
            await Task.yield()
        }
        try file.revalidate()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let temporaryName = ".pending-" + UUID().uuidString
        let out = openat(dirFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw LlamaCppProcessProbeError.unsafeFile }
        defer { Darwin.close(out); unlinkat(dirFD, temporaryName, 0) }
        guard hash.withCString({ Darwin.write(out, $0, 64) }) == 64, fsync(out) == 0,
              renameat(dirFD, temporaryName, dirFD, url.lastPathComponent) == 0,
              fsync(dirFD) == 0 else { throw LlamaCppProcessProbeError.unsafeFile }
        return hash
    }

    private static func command(_ path: String, _ args: [String]) async throws -> Data {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        process.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "HOME":NSHomeDirectory()]
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        try process.run(); try? pipe.fileHandleForWriting.close()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? pipe.fileHandleForReading.close() }
        let deadline = ContinuousClock.now + .seconds(5); var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { result.append(contentsOf: buffer.prefix(n)); guard result.count <= 16_384 else { throw LlamaCppProcessProbeError.outputTooLarge } }
            else if n == 0 && !process.isRunning { break }
            else if n < 0 && errno != EAGAIN && errno != EINTR { throw LlamaCppProcessProbeError.unverified }
            guard ContinuousClock.now < deadline else { throw LlamaCppProcessProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard process.terminationStatus == 0 else { throw LlamaCppProcessProbeError.unverified }
        return result
    }
}

final class PinnedLocalFile {
    struct Identity: Codable, Equatable {
        let path: String; let size: Int64; let modified: Int64; let changed: Int64; let device: Int32; let inode: UInt64
    }
    let fd: Int32; let path: String; let identity: Identity; private let original: String
    init(_ path: String, executable: Bool) throws {
        original = path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard executable ? URL(fileURLWithPath: resolved).lastPathComponent == "llama-server" : URL(fileURLWithPath: resolved).pathExtension.lowercased() == "gguf" else { throw LlamaCppProcessProbeError.unsafeFile }
        let descriptor = Darwin.open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LlamaCppProcessProbeError.unsafeFile }
        do {
            let id = try Self.readIdentity(descriptor, resolved)
            if executable { guard access(resolved, X_OK) == 0 else { throw LlamaCppProcessProbeError.unsafeFile }
                var magic: UInt32 = 0; guard pread(descriptor, &magic, 4, 0) == 4, [0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca].contains(magic) else { throw LlamaCppProcessProbeError.unsafeFile }
            }
            fd = descriptor; self.path = resolved; identity = id
        } catch { Darwin.close(descriptor); throw error }
    }
    deinit { Darwin.close(fd) }
    func revalidate() throws {
        guard URL(fileURLWithPath: original).resolvingSymlinksInPath().standardizedFileURL.path == path,
              try Self.readIdentity(fd, path) == identity else { throw LlamaCppProcessProbeError.identityChanged }
    }
    private static func readIdentity(_ fd: Int32, _ path: String) throws -> Identity {
        var st = stat(); var ps = stat(); var fs = statfs()
        guard fstat(fd, &st) == 0, lstat(path, &ps) == 0, fstatfs(fd, &fs) == 0,
              st.st_mode & S_IFMT == S_IFREG, st.st_ino == ps.st_ino, st.st_dev == ps.st_dev,
              st.st_size > 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw LlamaCppProcessProbeError.unsafeFile }
        return Identity(path: path, size: st.st_size, modified: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), changed: Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec), device: st.st_dev, inode: st.st_ino)
    }
}

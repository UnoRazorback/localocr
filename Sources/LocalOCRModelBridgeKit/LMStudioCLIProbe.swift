import Darwin
import Dispatch
import Foundation

public protocol LMStudioCLIProbing: Sendable {
    func linkStatus() async throws -> LMStudioLinkStatus
    func localModels() async throws -> [LMStudioLocalModel]
    func version() async throws -> String
    func snapshot() async throws -> LMStudioCLISnapshot
}

public extension LMStudioCLIProbing {
    func snapshot() async throws -> LMStudioCLISnapshot {
        let version = try await version()
        let models = try await localModels()
        let link = try await linkStatus()
        return LMStudioCLISnapshot(link: link, models: models, version: version)
    }
}

public struct LMStudioCLISnapshot: Sendable, Equatable {
    public let link: LMStudioLinkStatus
    public let models: [LMStudioLocalModel]
    public let version: String

    public init(link: LMStudioLinkStatus, models: [LMStudioLocalModel], version: String) {
        self.link = link
        self.models = models
        self.version = version
    }
}

public struct LMStudioLinkPeer: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case connected
        case disconnected
    }

    public let deviceIdentifier: String
    public let deviceName: String
    public let status: Status
    public let loadedModels: [String]

    public init(
        deviceIdentifier: String,
        deviceName: String,
        status: Status,
        loadedModels: [String]
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.status = status
        self.loadedModels = loadedModels
    }
}

public struct LMStudioLinkStatus: Sendable, Equatable {
    public let enabled: Bool
    public let peers: [LMStudioLinkPeer]

    public var connectedPeerCount: Int {
        peers.count { $0.status == .connected }
    }

    public init(enabled: Bool, peers: [LMStudioLinkPeer]) {
        self.enabled = enabled
        self.peers = peers
    }

    public init(enabled: Bool, connectedPeerCount: Int) {
        self.enabled = enabled
        peers = (0..<max(0, connectedPeerCount)).map { index in
            LMStudioLinkPeer(
                deviceIdentifier: "fixture-peer-\(index)",
                deviceName: "Fixture peer \(index)",
                status: .connected,
                loadedModels: []
            )
        }
    }
}

public struct LMStudioLocalModel: Sendable, Equatable {
    public let key: String
    public let selectedVariant: String?
    public let architecture: String?
    public let format: String
    public let quantization: String?
    public let sizeBytes: Int64
    public let deviceIdentifier: String?

    public init(
        key: String,
        selectedVariant: String?,
        architecture: String?,
        format: String,
        quantization: String?,
        sizeBytes: Int64,
        deviceIdentifier: String? = nil
    ) {
        self.key = key
        self.selectedVariant = selectedVariant
        self.architecture = architecture
        self.format = format
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.deviceIdentifier = deviceIdentifier
    }
}

public enum LMStudioCLIProbeError: Error, Sendable, Equatable {
    case missingExecutable
    case unsafeExecutable
    case invalidOutput
    case commandFailed
    case outputTooLarge
    case timedOut
    case cancelled
}

public struct LMStudioCLIProbe: LMStudioCLIProbing, Sendable {
    static let maximumOutputBytes = 1_048_576
    private static let readerShutdownBudget = Duration.seconds(1)
    private static let pollInterval = Duration.milliseconds(5)

    private let homeDirectory: URL
    private let commandTimeout: Duration
    private let terminationGracePeriod: Duration

    public init() {
        homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
        commandTimeout = .seconds(5)
        terminationGracePeriod = .milliseconds(250)
    }

    init(
        homeDirectory: URL,
        commandTimeout: Duration = .seconds(5),
        terminationGracePeriod: Duration = .milliseconds(250)
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.commandTimeout = commandTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func snapshot() async throws -> LMStudioCLISnapshot {
        let executable = try PinnedExecutable(homeDirectory: homeDirectory)
        defer { executable.close() }
        let version = try parseVersion(try await run(.version, executable: executable))
        let models = try parseModels(try await run(.localModels, executable: executable))
        let link = try parseLink(try await run(.linkStatus, executable: executable))
        return LMStudioCLISnapshot(link: link, models: models, version: version)
    }

    public func linkStatus() async throws -> LMStudioLinkStatus {
        let executable = try PinnedExecutable(homeDirectory: homeDirectory)
        defer { executable.close() }
        return try parseLink(try await run(.linkStatus, executable: executable))
    }

    public func localModels() async throws -> [LMStudioLocalModel] {
        let executable = try PinnedExecutable(homeDirectory: homeDirectory)
        defer { executable.close() }
        return try parseModels(try await run(.localModels, executable: executable))
    }

    public func version() async throws -> String {
        let executable = try PinnedExecutable(homeDirectory: homeDirectory)
        defer { executable.close() }
        return try parseVersion(try await run(.version, executable: executable))
    }

    private func parseLink(_ data: Data) throws -> LMStudioLinkStatus {
        let result: LinkStatusOutput
        do {
            result = try JSONDecoder().decode(LinkStatusOutput.self, from: data)
        } catch {
            throw LMStudioCLIProbeError.invalidOutput
        }
        let issues = Set(result.issues)
        guard issues.count == result.issues.count,
              result.hasBoundedIdentity else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        let disabled = issues.contains(.deviceDisabled)
        let peers = result.peers.map { peer in
            LMStudioLinkPeer(
                deviceIdentifier: peer.deviceIdentifier,
                deviceName: peer.deviceName,
                status: peer.status == .connected ? .connected : .disconnected,
                loadedModels: peer.loadedModels
            )
        }
        if disabled && (result.status != .offline || peers.contains { $0.status == .connected }) {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return LMStudioLinkStatus(enabled: !disabled, peers: peers)
    }

    private func parseModels(_ data: Data) throws -> [LMStudioLocalModel] {
        let models: [LocalModelOutput]
        do {
            models = try JSONDecoder().decode([LocalModelOutput].self, from: data)
        } catch {
            throw LMStudioCLIProbeError.invalidOutput
        }
        guard models.allSatisfy(\.hasBoundedIdentity) else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return models.map { model in
            LMStudioLocalModel(
                key: model.modelKey,
                selectedVariant: model.selectedVariant,
                architecture: model.architecture,
                format: model.format,
                quantization: model.quantization?.name,
                sizeBytes: model.sizeBytes,
                deviceIdentifier: model.deviceIdentifier
            )
        }
    }

    private func parseVersion(_ data: Data) throws -> String {
        guard let output = String(data: data, encoding: .utf8) else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        let lines = output.split(whereSeparator: \Character.isNewline)
        let prefix = "CLI commit: "
        guard lines.count == 1,
              output == String(lines[0]) || output == "\(lines[0])\n",
              lines[0].hasPrefix(prefix),
              lines[0].dropFirst(prefix.count).count <= 256 else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        let version = String(lines[0].dropFirst(prefix.count))
        guard Self.validIdentityString(version) else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return version
    }

    private func run(
        _ command: Command,
        executable: PinnedExecutable
    ) async throws -> Data {
        try executable.revalidate()
        let child: SpawnedCommand
        do {
            child = try SpawnedCommand(
                executable: executable.url.path,
                arguments: command.arguments,
                environment: ["HOME=\(homeDirectory.path)", "PATH="]
            )
        } catch {
            try executable.revalidate()
            throw error
        }
        let stdoutCollector = BoundedProcessOutput(limit: Self.maximumOutputBytes)
        let stderrCollector = BoundedProcessOutput(limit: Self.maximumOutputBytes)
        let readers = DispatchGroup()
        Self.startReader(child.stdoutFD, collector: stdoutCollector, group: readers)
        Self.startReader(child.stderrFD, collector: stderrCollector, group: readers)

        var status: Int32?
        var terminalError: LMStudioCLIProbeError?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: commandTimeout)

        while status == nil && terminalError == nil {
            status = try child.pollStatus()
            if status != nil { break }
            if Task.isCancelled {
                terminalError = .cancelled
            } else if stdoutCollector.exceededLimit || stderrCollector.exceededLimit {
                terminalError = .outputTooLarge
            } else if clock.now >= deadline {
                terminalError = .timedOut
            } else {
                try? await Task.sleep(for: Self.pollInterval)
            }
        }

        if terminalError != nil {
            status = try await child.terminateGroupAndReap(
                currentStatus: status,
                gracePeriod: terminationGracePeriod
            )
        } else if !(await Self.waitForReaders(readers, timeout: terminationGracePeriod)) {
            terminalError = .commandFailed
            status = try await child.terminateGroupAndReap(
                currentStatus: status,
                gracePeriod: terminationGracePeriod
            )
        }

        if !(await Self.waitForReaders(readers, timeout: Self.readerShutdownBudget)) {
            terminalError = .commandFailed
            child.closeReadDescriptors()
            _ = await Self.waitForReaders(readers, timeout: .milliseconds(100))
        } else {
            child.closeReadDescriptors()
        }
        try executable.revalidate()

        if let terminalError {
            throw terminalError
        }
        guard let status,
              status == 0,
              !stdoutCollector.exceededLimit,
              !stderrCollector.exceededLimit,
              !stdoutCollector.readFailed,
              !stderrCollector.readFailed else {
            throw stdoutCollector.exceededLimit || stderrCollector.exceededLimit
                ? LMStudioCLIProbeError.outputTooLarge
                : LMStudioCLIProbeError.commandFailed
        }
        return stdoutCollector.data
    }

    private static func startReader(
        _ descriptor: Int32,
        collector: BoundedProcessOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    collector.append(Data(buffer.prefix(count)))
                } else if count == 0 {
                    return
                } else if errno != EINTR {
                    collector.markReadFailed()
                    return
                }
            }
        }
    }

    private static func dispatchDeadline(after duration: Duration) -> DispatchTime {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + max(1, components.attoseconds / 1_000_000_000_000_000)
        return .now() + .milliseconds(Int(clamping: milliseconds))
    }

    private static func waitForReaders(
        _ readers: DispatchGroup,
        timeout: Duration
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = ReaderWaitGate(continuation: continuation)
            readers.notify(queue: .global(qos: .userInitiated)) {
                gate.resume(with: true)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: dispatchDeadline(after: timeout)
            ) {
                gate.resume(with: false)
            }
        }
    }

    private static func validIdentityString(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf8.count <= 4_096
    }
}

private final class ReaderWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private extension LMStudioCLIProbe {
    enum Command {
        case linkStatus
        case localModels
        case version

        var arguments: [String] {
            switch self {
            case .linkStatus: ["link", "status", "--json"]
            case .localModels: ["ls", "--llm", "--json"]
            case .version: ["--version"]
            }
        }
    }
}

private final class PinnedExecutable {
    let url: URL
    private let logicalExecutable: URL
    private let logicalBin: URL
    private let descriptor: Int32
    private let identity: ExecutableIdentity
    private let closeLock = NSLock()
    private var isClosed = false

    init(homeDirectory: URL) throws {
        logicalBin = homeDirectory
            .appendingPathComponent(".lmstudio", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        logicalExecutable = logicalBin.appendingPathComponent("lms", isDirectory: false)
        guard FileManager.default.fileExists(atPath: logicalExecutable.path) else {
            throw LMStudioCLIProbeError.missingExecutable
        }
        let physicalBin = logicalBin.resolvingSymlinksInPath().standardizedFileURL
        let physicalExecutable = logicalExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard physicalExecutable.deletingLastPathComponent() == physicalBin else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        let fd = Darwin.open(physicalExecutable.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        do {
            let identity = try Self.identity(descriptor: fd, path: physicalExecutable.path)
            try Self.validateInterpreter(descriptor: fd)
            url = physicalExecutable
            descriptor = fd
            self.identity = identity
            try revalidate()
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func revalidate() throws {
        let physicalBin = logicalBin.resolvingSymlinksInPath().standardizedFileURL
        let currentURL = logicalExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard currentURL == url,
              currentURL.deletingLastPathComponent() == physicalBin,
              try Self.identity(descriptor: descriptor, path: currentURL.path) == identity else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
    }

    func close() {
        closeLock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
        }
    }

    private static func identity(descriptor: Int32, path: String) throws -> ExecutableIdentity {
        var descriptorStat = stat()
        var pathStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
              lstat(path, &pathStat) == 0,
              descriptorStat.st_dev == pathStat.st_dev,
              descriptorStat.st_ino == pathStat.st_ino,
              (descriptorStat.st_mode & S_IFMT) == S_IFREG,
              descriptorStat.st_uid == getuid() || descriptorStat.st_uid == 0,
              access(path, X_OK) == 0 else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        return ExecutableIdentity(
            device: UInt64(descriptorStat.st_dev),
            inode: UInt64(descriptorStat.st_ino),
            owner: descriptorStat.st_uid,
            mode: descriptorStat.st_mode,
            size: descriptorStat.st_size
        )
    }

    private static func validateInterpreter(descriptor: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count >= 0 else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        guard count >= 2, bytes[0] == 35, bytes[1] == 33 else { return }
        let lineBytes = bytes.prefix(count).prefix { $0 != 10 && $0 != 13 }
        guard let line = String(bytes: lineBytes, encoding: .utf8) else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        let interpreter = line.dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        guard let interpreter,
              interpreter.hasPrefix("/"),
              interpreter != "/usr/bin/env" else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
    }
}

private struct ExecutableIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let mode: mode_t
    let size: off_t
}

private final class SpawnedCommand {
    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32
    private let lock = NSLock()
    private var reapedStatus: Int32?
    private var descriptorsClosed = false

    init(executable: String, arguments: [String], environment: [String]) throws {
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }
        let nullFD = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullFD >= 0 else {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            Darwin.close(nullFD)
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            Darwin.close(nullFD)
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var setupOK = true
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0
        for descriptor in [nullFD, stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            setupOK = setupOK && posix_spawn_file_actions_addclose(&actions, descriptor) == 0
        }
        setupOK = setupOK && posix_spawnattr_setpgroup(&attributes, 0) == 0
        setupOK = setupOK && posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        ) == 0
        guard setupOK else {
            Darwin.close(nullFD)
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }

        var spawnedPID: pid_t = 0
        let spawnResult = Self.withCStringArray([executable] + arguments) { argv in
            Self.withCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &spawnedPID,
                    executable,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        Darwin.close(nullFD)
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        guard spawnResult == 0, spawnedPID > 0, getpgid(spawnedPID) == spawnedPID else {
            Darwin.close(stdoutPipe[0])
            Darwin.close(stderrPipe[0])
            if spawnedPID > 0 {
                kill(spawnedPID, SIGKILL)
                var status: Int32 = 0
                waitpid(spawnedPID, &status, 0)
            }
            throw LMStudioCLIProbeError.commandFailed
        }
        pid = spawnedPID
        stdoutFD = stdoutPipe[0]
        stderrFD = stderrPipe[0]
    }

    func pollStatus() throws -> Int32? {
        if let status = lock.withLock({ reapedStatus }) { return status }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            lock.withLock { reapedStatus = status }
            return status
        }
        if result == 0 { return nil }
        if result == -1, errno == EINTR { return nil }
        if result == -1, errno == ECHILD,
           let status = lock.withLock({ reapedStatus }) {
            return status
        }
        throw LMStudioCLIProbeError.commandFailed
    }

    func terminateGroupAndReap(
        currentStatus: Int32?,
        gracePeriod: Duration
    ) async throws -> Int32 {
        var status = currentStatus
        kill(-pid, SIGTERM)
        let clock = ContinuousClock()
        let graceDeadline = clock.now.advanced(by: gracePeriod)
        while status == nil && clock.now < graceDeadline {
            status = try pollStatus()
            if status == nil { try? await Task.sleep(for: .milliseconds(5)) }
        }
        kill(-pid, SIGKILL)
        while status == nil {
            status = try pollStatus()
            if status == nil { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let groupDeadline = clock.now.advanced(by: .seconds(1))
        while kill(-pid, 0) == 0 && clock.now < groupDeadline {
            kill(-pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return status ?? -1
    }

    func closeReadDescriptors() {
        lock.withLock {
            guard !descriptorsClosed else { return }
            descriptorsClosed = true
            Darwin.close(stdoutFD)
            Darwin.close(stderrFD)
        }
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func closePipe(_ descriptors: [Int32]) {
        descriptors.filter { $0 >= 0 }.forEach { Darwin.close($0) }
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storedData = Data()
    private var limitExceeded = false
    private var failed = false

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data { lock.withLock { storedData } }
    var exceededLimit: Bool { lock.withLock { limitExceeded } }
    var readFailed: Bool { lock.withLock { failed } }

    func append(_ data: Data) {
        lock.withLock {
            let available = max(0, limit - storedData.count)
            if data.count > available {
                storedData.append(data.prefix(available))
                limitExceeded = true
            } else {
                storedData.append(data)
            }
        }
    }

    func markReadFailed() {
        lock.withLock { failed = true }
    }
}

private struct LinkStatusOutput: Decodable {
    enum Status: String, Decodable { case offline, starting, online, stopping }
    enum Issue: String, Decodable { case deviceDisabled, notLoggedIn, noAccess, badVersion }

    struct Peer: Decodable {
        enum Status: String, Decodable { case connected, disconnected }
        let deviceIdentifier: String
        let deviceName: String
        let status: Status
        let loadedModels: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case deviceIdentifier, deviceName, status, loadedModels
        }

        init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceIdentifier = try container.decode(String.self, forKey: .deviceIdentifier)
            deviceName = try container.decode(String.self, forKey: .deviceName)
            status = try container.decode(Status.self, forKey: .status)
            loadedModels = try container.decode([String].self, forKey: .loadedModels)
        }

        var hasBoundedIdentity: Bool {
            [deviceIdentifier, deviceName].allSatisfy(validEvidenceString)
                && loadedModels.allSatisfy(validEvidenceString)
        }
    }

    let status: Status
    let issues: [Issue]
    let peers: [Peer]
    let deviceIdentifier: String?
    let deviceName: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case status, issues, peers, deviceIdentifier, deviceName
        case preferredDeviceIdentifier, reconnectInSeconds, lastError
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        issues = try container.decode([Issue].self, forKey: .issues)
        peers = try container.decode([Peer].self, forKey: .peers)
        guard container.contains(.deviceIdentifier) else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceIdentifier,
                .init(codingPath: decoder.codingPath, debugDescription: "Link device marker is required.")
            )
        }
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        _ = try container.decodeIfPresent(String.self, forKey: .preferredDeviceIdentifier)
        _ = try container.decodeIfPresent(Int.self, forKey: .reconnectInSeconds)
        _ = try container.decodeIfPresent(LastError.self, forKey: .lastError)
    }

    var hasBoundedIdentity: Bool {
        validEvidenceString(deviceName)
            && (deviceIdentifier.map(validEvidenceString) ?? true)
            && peers.allSatisfy(\.hasBoundedIdentity)
    }

    private struct LastError: Decodable {
        let message: String
        let timestamp: Int64
    }
}

private struct LocalModelOutput: Decodable {
    let type: String
    let modelKey: String
    let format: String
    let displayName: String
    let publisher: String
    let path: String
    let sizeBytes: Int64
    let indexedModelIdentifier: String
    let deviceIdentifier: String?
    let paramsString: String?
    let architecture: String?
    let quantization: Quantization?
    let variants: [String]?
    let selectedVariant: String?
    let vision: Bool
    let trainedForToolUse: Bool
    let maxContextLength: Int64

    struct Quantization: Decodable {
        let name: String
        let bits: Int
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, modelKey, format, displayName, publisher, path, sizeBytes
        case indexedModelIdentifier, deviceIdentifier, paramsString, architecture
        case quantization, variants, selectedVariant, vision, trainedForToolUse
        case maxContextLength
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        modelKey = try container.decode(String.self, forKey: .modelKey)
        format = try container.decode(String.self, forKey: .format)
        displayName = try container.decode(String.self, forKey: .displayName)
        publisher = try container.decode(String.self, forKey: .publisher)
        path = try container.decode(String.self, forKey: .path)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        indexedModelIdentifier = try container.decode(String.self, forKey: .indexedModelIdentifier)
        guard container.contains(.deviceIdentifier) else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceIdentifier,
                .init(codingPath: decoder.codingPath, debugDescription: "Locality marker is required.")
            )
        }
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        paramsString = try container.decodeIfPresent(String.self, forKey: .paramsString)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
        quantization = try container.decodeIfPresent(Quantization.self, forKey: .quantization)
        variants = try container.decodeIfPresent([String].self, forKey: .variants)
        selectedVariant = try container.decodeIfPresent(String.self, forKey: .selectedVariant)
        vision = try container.decode(Bool.self, forKey: .vision)
        trainedForToolUse = try container.decode(Bool.self, forKey: .trainedForToolUse)
        maxContextLength = try container.decode(Int64.self, forKey: .maxContextLength)
    }

    var hasBoundedIdentity: Bool {
        type == "llm"
            && [modelKey, format, displayName, publisher, path, indexedModelIdentifier]
                .allSatisfy(validEvidenceString)
            && (deviceIdentifier.map(validEvidenceString) ?? true)
            && (architecture.map(validEvidenceString) ?? true)
            && (quantization.map { validEvidenceString($0.name) && $0.bits > 0 } ?? true)
            && (selectedVariant.map(validEvidenceString) ?? true)
            && (variants?.allSatisfy(validEvidenceString) ?? true)
            && maxContextLength > 0
    }
}

private func validEvidenceString(_ value: String) -> Bool {
    !value.isEmpty
        && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && value.utf8.count <= 4_096
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private func rejectUnknownKeys(in decoder: any Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown keys are not allowed.")
        )
    }
}

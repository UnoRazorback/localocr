import Darwin
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
    public let variants: [String]?
    public let architecture: String?
    public let format: String
    public let quantization: String?
    public let sizeBytes: Int64
    public let deviceIdentifier: String?

    public init(
        key: String,
        selectedVariant: String?,
        variants: [String]? = nil,
        architecture: String?,
        format: String,
        quantization: String?,
        sizeBytes: Int64,
        deviceIdentifier: String? = nil
    ) {
        self.key = key
        self.selectedVariant = selectedVariant
        self.variants = variants
        self.architecture = architecture
        self.format = format
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.deviceIdentifier = deviceIdentifier
    }

    var hasConsistentVariantEvidence: Bool {
        switch (variants, selectedVariant) {
        case (nil, nil):
            true
        case let (.some(variants), .some(selected)):
            !variants.isEmpty
                && Set(variants).count == variants.count
                && variants.filter { $0 == selected }.count == 1
        default:
            false
        }
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
                variants: model.variants,
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
        do {
            let data = try await LMStudioCommandRunner(
                commandTimeout: commandTimeout,
                terminationGracePeriod: terminationGracePeriod,
                cleanupBudget: .seconds(1),
                pipeDrainBudget: terminationGracePeriod,
                maximumOutputBytes: Self.maximumOutputBytes
            ).run(
                executableDescriptor: executable.executionDescriptor,
                displayPath: executable.url.path,
                arguments: command.arguments,
                environment: ["HOME=\(homeDirectory.path)", "PATH="]
            )
            try executable.revalidate()
            return data
        } catch {
            try executable.revalidate()
            throw error
        }
    }

    private static func validIdentityString(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf8.count <= 4_096
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
    var executionDescriptor: Int32 { descriptor }
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
        guard interpreter.count == 1,
              interpreter.first == "/bin/sh" else {
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

struct LMStudioCommandRunner: Sendable {
    let commandTimeout: Duration
    let terminationGracePeriod: Duration
    let cleanupBudget: Duration
    let pipeDrainBudget: Duration
    let maximumOutputBytes: Int

    func run(
        executableDescriptor: Int32,
        displayPath: String,
        arguments: [String],
        environment: [String]
    ) async throws -> Data {
        let command = try SpawnedCommand(
            executableDescriptor: executableDescriptor,
            displayPath: displayPath,
            arguments: arguments,
            environment: environment
        )
        defer { command.closeReadDescriptors() }
        do {
            try command.verifyIsolatedProcessGroup()
        } catch {
            try await command.terminateUnverifiedProcess(cleanupBudget: cleanupBudget)
            throw LMStudioCLIProbeError.commandFailed
        }

        let system = DarwinLMStudioProcessSystem()
        let clock = ContinuousClock()
        let commandDeadline = clock.now.advanced(by: commandTimeout)
        var drainDeadline: ContinuousClock.Instant?
        var status: Int32?
        var stdout = PipeCapture(limit: maximumOutputBytes)
        var stderr = PipeCapture(limit: maximumOutputBytes)

        while true {
            stdout.drain(descriptor: command.stdoutFD)
            stderr.drain(descriptor: command.stderrFD)

            if stdout.exceededLimit || stderr.exceededLimit {
                try await abort(
                    command: command,
                    currentStatus: status,
                    stdout: &stdout,
                    stderr: &stderr,
                    error: .outputTooLarge,
                    system: system
                )
            }
            if stdout.readFailed || stderr.readFailed {
                try await abort(
                    command: command,
                    currentStatus: status,
                    stdout: &stdout,
                    stderr: &stderr,
                    error: .commandFailed,
                    system: system
                )
            }
            if Task.isCancelled {
                try await abort(
                    command: command,
                    currentStatus: status,
                    stdout: &stdout,
                    stderr: &stderr,
                    error: .cancelled,
                    system: system
                )
            }

            if status == nil {
                status = try system.pollStatus(of: command.pid)
                if status != nil {
                    drainDeadline = clock.now.advanced(by: pipeDrainBudget)
                }
            }
            if let status, stdout.reachedEOF, stderr.reachedEOF {
                if try system.processGroupExists(command.pid) {
                    try await abort(
                        command: command,
                        currentStatus: status,
                        stdout: &stdout,
                        stderr: &stderr,
                        error: .commandFailed,
                        system: system
                    )
                }
                guard status == 0 else {
                    throw LMStudioCLIProbeError.commandFailed
                }
                return stdout.data
            }
            if let drainDeadline, clock.now >= drainDeadline {
                try await abort(
                    command: command,
                    currentStatus: status,
                    stdout: &stdout,
                    stderr: &stderr,
                    error: .commandFailed,
                    system: system
                )
            }
            if clock.now >= commandDeadline {
                try await abort(
                    command: command,
                    currentStatus: status,
                    stdout: &stdout,
                    stderr: &stderr,
                    error: .timedOut,
                    system: system
                )
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func abort(
        command: SpawnedCommand,
        currentStatus: Int32?,
        stdout: inout PipeCapture,
        stderr: inout PipeCapture,
        error: LMStudioCLIProbeError,
        system: any LMStudioProcessSystemCalling
    ) async throws -> Never {
        _ = try await LMStudioProcessGroupCleanup.terminateAndReap(
            pid: command.pid,
            currentStatus: currentStatus,
            gracePeriod: terminationGracePeriod,
            cleanupBudget: cleanupBudget,
            system: system
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pipeDrainBudget)
        repeat {
            stdout.drain(descriptor: command.stdoutFD)
            stderr.drain(descriptor: command.stderrFD)
            if stdout.reachedEOF, stderr.reachedEOF { throw error }
            if stdout.readFailed || stderr.readFailed {
                throw LMStudioCLIProbeError.commandFailed
            }
            try? await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        throw LMStudioCLIProbeError.commandFailed
    }
}

protocol LMStudioProcessSystemCalling: Sendable {
    func sendSignal(_ signal: Int32, toProcessGroup pid: pid_t) throws
    func pollStatus(of pid: pid_t) throws -> Int32?
    func processGroupExists(_ pid: pid_t) throws -> Bool
}

struct LMStudioProcessGroupCleanup {
    static func terminateAndReap(
        pid: pid_t,
        currentStatus: Int32?,
        gracePeriod: Duration,
        cleanupBudget: Duration,
        system: any LMStudioProcessSystemCalling
    ) async throws -> Int32 {
        let clock = ContinuousClock()
        let graceDeadline = clock.now.advanced(by: gracePeriod)
        let cleanupDeadline = graceDeadline.advanced(by: cleanupBudget)
        var status = currentStatus

        try system.sendSignal(SIGTERM, toProcessGroup: pid)
        while clock.now < graceDeadline {
            if status == nil { status = try system.pollStatus(of: pid) }
            if let status, try !system.processGroupExists(pid) { return status }
            try? await Task.sleep(for: .milliseconds(5))
        }

        try system.sendSignal(SIGKILL, toProcessGroup: pid)
        while clock.now < cleanupDeadline {
            if status == nil { status = try system.pollStatus(of: pid) }
            let groupExists = try system.processGroupExists(pid)
            if let status, !groupExists { return status }
            try? await Task.sleep(for: .milliseconds(5))
        }

        if status == nil { status = try system.pollStatus(of: pid) }
        guard let status, try !system.processGroupExists(pid) else {
            throw LMStudioCLIProbeError.commandFailed
        }
        return status
    }
}

private struct DarwinLMStudioProcessSystem: LMStudioProcessSystemCalling {
    func sendSignal(_ signal: Int32, toProcessGroup pid: pid_t) throws {
        guard kill(-pid, signal) == 0 || errno == ESRCH else {
            throw LMStudioCLIProbeError.commandFailed
        }
    }

    func pollStatus(of pid: pid_t) throws -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return status }
        if result == 0 || (result == -1 && errno == EINTR) { return nil }
        throw LMStudioCLIProbeError.commandFailed
    }

    func processGroupExists(_ pid: pid_t) throws -> Bool {
        if kill(-pid, 0) == 0 { return true }
        if errno == ESRCH { return false }
        if errno == EPERM { return true }
        throw LMStudioCLIProbeError.commandFailed
    }
}

private final class SpawnExecutionPlan {
    let spawnPath: String
    let argv: [String]
    let inheritedDescriptors: [Int32]
    private let executableReadDescriptor: Int32
    private let executableIdentity: ExecutableIdentity
    private let interpreterDescriptor: Int32?
    private let interpreterIdentity: ExecutableIdentity?

    init(
        executableDescriptor: Int32,
        displayPath: String,
        arguments: [String]
    ) throws {
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = pread(executableDescriptor, &bytes, bytes.count, 0)
        guard count >= 0 else { throw LMStudioCLIProbeError.commandFailed }
        let readIdentity = try Self.descriptorIdentity(executableDescriptor)
        executableReadDescriptor = executableDescriptor
        executableIdentity = readIdentity
        // macOS devfs cannot be executed directly. A fixed root-owned interpreter
        // may read this inherited descriptor; every other executable form fails closed.
        guard count >= 2, bytes[0] == 35, bytes[1] == 33 else {
            throw LMStudioCLIProbeError.commandFailed
        }

        let lineBytes = bytes.prefix(count).prefix { $0 != 10 && $0 != 13 }
        guard let line = String(bytes: lineBytes, encoding: .utf8),
              line.dropFirst(2).trimmingCharacters(in: .whitespaces) == "/bin/sh" else {
            throw LMStudioCLIProbeError.commandFailed
        }
        let interpreterPath = "/bin/sh"
        let descriptor = Darwin.open(interpreterPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor > STDERR_FILENO else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw LMStudioCLIProbeError.commandFailed
        }
        do {
            let identity = try Self.interpreterIdentity(
                descriptor: descriptor,
                path: interpreterPath
            )
            spawnPath = interpreterPath
            argv = [interpreterPath, "/dev/fd/\(executableDescriptor)"] + arguments
            inheritedDescriptors = [executableDescriptor]
            interpreterDescriptor = descriptor
            interpreterIdentity = identity
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func revalidate() -> Bool {
        guard (try? Self.descriptorIdentity(executableReadDescriptor)) == executableIdentity else {
            return false
        }
        guard let interpreterDescriptor, let interpreterIdentity else { return true }
        return (try? Self.interpreterIdentity(
            descriptor: interpreterDescriptor,
            path: "/bin/sh"
        )) == interpreterIdentity
    }

    func close() {
        if let interpreterDescriptor { Darwin.close(interpreterDescriptor) }
    }

    private static func descriptorIdentity(_ descriptor: Int32) throws -> ExecutableIdentity {
        var descriptorStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
              (descriptorStat.st_mode & S_IFMT) == S_IFREG else {
            throw LMStudioCLIProbeError.commandFailed
        }
        return ExecutableIdentity(
            device: UInt64(descriptorStat.st_dev),
            inode: UInt64(descriptorStat.st_ino),
            owner: descriptorStat.st_uid,
            mode: descriptorStat.st_mode,
            size: descriptorStat.st_size
        )
    }

    private static func interpreterIdentity(
        descriptor: Int32,
        path: String
    ) throws -> ExecutableIdentity {
        var descriptorStat = stat()
        var pathStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
              lstat(path, &pathStat) == 0,
              descriptorStat.st_dev == pathStat.st_dev,
              descriptorStat.st_ino == pathStat.st_ino,
              (descriptorStat.st_mode & S_IFMT) == S_IFREG,
              descriptorStat.st_uid == 0,
              access(path, X_OK) == 0 else {
            throw LMStudioCLIProbeError.commandFailed
        }
        return ExecutableIdentity(
            device: UInt64(descriptorStat.st_dev),
            inode: UInt64(descriptorStat.st_ino),
            owner: descriptorStat.st_uid,
            mode: descriptorStat.st_mode,
            size: descriptorStat.st_size
        )
    }
}

private final class SpawnedCommand: @unchecked Sendable {
    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32
    private let descriptorLock = NSLock()
    private var descriptorsClosed = false

    init(
        executableDescriptor: Int32,
        displayPath: String,
        arguments: [String],
        environment: [String]
    ) throws {
        guard executableDescriptor > STDERR_FILENO,
              fcntl(executableDescriptor, F_GETFD) >= 0 else {
            throw LMStudioCLIProbeError.commandFailed
        }
        let executionPlan = try SpawnExecutionPlan(
            executableDescriptor: executableDescriptor,
            displayPath: displayPath,
            arguments: arguments
        )
        defer { executionPlan.close() }
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }
        guard Self.makeNonblocking(stdoutPipe[0]),
              Self.makeNonblocking(stderrPipe[0]) else {
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
        for descriptor in executionPlan.inheritedDescriptors {
            setupOK = setupOK
                && posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0
        }
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0
        for descriptor in [nullFD, stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            setupOK = setupOK && posix_spawn_file_actions_addclose(&actions, descriptor) == 0
        }
        setupOK = setupOK && posix_spawnattr_setpgroup(&attributes, 0) == 0
        setupOK = setupOK && posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0
        guard setupOK else {
            Darwin.close(nullFD)
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }
        guard executionPlan.revalidate() else {
            Darwin.close(nullFD)
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw LMStudioCLIProbeError.commandFailed
        }

        var spawnedPID: pid_t = 0
        let spawnResult = Self.withCStringArray(executionPlan.argv) { argv in
            Self.withCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &spawnedPID,
                    executionPlan.spawnPath,
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
        guard spawnResult == 0, spawnedPID > 0 else {
            Darwin.close(stdoutPipe[0])
            Darwin.close(stderrPipe[0])
            throw LMStudioCLIProbeError.commandFailed
        }
        pid = spawnedPID
        stdoutFD = stdoutPipe[0]
        stderrFD = stderrPipe[0]
    }

    func verifyIsolatedProcessGroup() throws {
        guard getpgid(pid) == pid else {
            throw LMStudioCLIProbeError.commandFailed
        }
    }

    func terminateUnverifiedProcess(cleanupBudget: Duration) async throws {
        let directResult = kill(pid, SIGKILL)
        guard directResult == 0 || errno == ESRCH else {
            throw LMStudioCLIProbeError.commandFailed
        }
        let groupResult = kill(-pid, SIGKILL)
        guard groupResult == 0 || errno == ESRCH else {
            throw LMStudioCLIProbeError.commandFailed
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: cleanupBudget)
        var status: Int32?
        let system = DarwinLMStudioProcessSystem()
        while clock.now < deadline {
            if status == nil { status = try system.pollStatus(of: pid) }
            let groupExists = try system.processGroupExists(pid)
            if status != nil, !groupExists { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if status == nil { status = try system.pollStatus(of: pid) }
        guard status != nil, try !system.processGroupExists(pid) else {
            throw LMStudioCLIProbeError.commandFailed
        }
    }

    func closeReadDescriptors() {
        descriptorLock.withLock {
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

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }
}

private struct PipeCapture {
    private let limit: Int
    private(set) var data = Data()
    private(set) var exceededLimit = false
    private(set) var readFailed = false
    private(set) var reachedEOF = false

    init(limit: Int) {
        self.limit = limit
    }

    mutating func drain(descriptor: Int32) {
        guard !reachedEOF, !readFailed else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let available = max(0, limit - data.count)
                let accepted = min(available, count)
                if accepted > 0 { data.append(buffer, count: accepted) }
                if count > available { exceededLimit = true }
                continue
            }
            if count == 0 {
                reachedEOF = true
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            readFailed = true
            return
        }
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

import Darwin
import Foundation

public enum AgentClientCommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case refusedExecutable
    case launchFailed
    case outputTooLarge
    case timedOut
    case exited(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .refusedExecutable:
            "LocalOCR refused an unsafe client executable."
        case .launchFailed:
            "The selected agent client could not be opened."
        case .outputTooLarge:
            "The agent client returned more diagnostic output than LocalOCR accepts."
        case .timedOut:
            "The agent client did not finish in time."
        case let .exited(status):
            "The agent client reported an error (status \(status))."
        }
    }
}

public struct AgentClientCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public struct AgentClientCommandRunner: Sendable {
    public static let maximumOutputBytes = 1_048_576

    public init() {}

    public func run(
        _ spec: AgentClientCommandSpec,
        timeout: Duration = .seconds(8)
    ) async throws -> AgentClientCommandResult {
        guard Self.accepts(executableURL: spec.executableURL) else {
            throw AgentClientCommandRunnerError.refusedExecutable
        }
        return try await AgentClientProcessExecution(
            spec: spec,
            maximumOutputBytes: Self.maximumOutputBytes
        ).execute(timeout: timeout)
    }

    private static func accepts(executableURL: URL) -> Bool {
        guard executableURL.isFileURL else { return false }
        let refusedNames = Set(["sh", "bash", "zsh", "fish", "dash", "env"])
        return !refusedNames.contains(executableURL.lastPathComponent.lowercased())
    }
}

private final class AgentClientProcessExecution: @unchecked Sendable {
    private static let terminationGrace = Duration.milliseconds(200)

    private let spec: AgentClientCommandSpec
    private let accumulator: AgentClientOutputAccumulator
    private let lock = NSLock()
    private var process: Process?
    private var pipes: [Pipe] = []
    private var cancelled = false
    private var timedOut = false

    init(spec: AgentClientCommandSpec, maximumOutputBytes: Int) {
        self.spec = spec
        accumulator = AgentClientOutputAccumulator(maximumBytes: maximumOutputBytes)
    }

    func execute(timeout: Duration) async throws -> AgentClientCommandResult {
        try await withTaskCancellationHandler {
            do {
                return try await run(timeout: timeout)
            } catch {
                if wasCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            cancel()
        }
    }

    private func run(timeout: Duration) async throws -> AgentClientCommandResult {
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.standardOutput = output
        process.standardError = diagnostics
        process.standardInput = FileHandle.nullDevice

        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.process = process
            pipes = [output, diagnostics]
        }

        do {
            try process.run()
        } catch {
            cleanup()
            throw AgentClientCommandRunnerError.launchFailed
        }

        let processBox = AgentClientProcessBox(process)
        let stdoutTask = readTask(handle: output.fileHandleForReading, stream: .stdout)
        let stderrTask = readTask(handle: diagnostics.fileHandleForReading, stream: .stderr)
        let terminationTask = Task.detached {
            processBox.process.waitUntilExit()
            return processBox.process.terminationStatus
        }
        let timeoutTask = Task.detached { [self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            markTimedOutAndTerminate()
        }

        let status = await terminationTask.value
        timeoutTask.cancel()
        let stdoutResult = await stdoutTask.result
        let stderrResult = await stderrTask.result
        cleanup()

        try Task.checkCancellation()
        if wasCancelled { throw CancellationError() }
        if didTimeOut { throw AgentClientCommandRunnerError.timedOut }
        do {
            try stdoutResult.get()
            try stderrResult.get()
        } catch AgentClientCommandRunnerError.outputTooLarge {
            throw AgentClientCommandRunnerError.outputTooLarge
        } catch {
            throw AgentClientCommandRunnerError.launchFailed
        }
        guard status == 0 else {
            throw AgentClientCommandRunnerError.exited(status: status)
        }
        let captured = accumulator.snapshot()
        return AgentClientCommandResult(
            exitStatus: status,
            stdout: captured.stdout,
            stderr: captured.stderr
        )
    }

    private func readTask(
        handle: FileHandle,
        stream: AgentClientOutputStream
    ) -> Task<Void, Error> {
        Task.detached { [self] in
            do {
                while true {
                    let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                    if data.isEmpty { return }
                    try accumulator.append(data, to: stream)
                }
            } catch AgentClientCommandRunnerError.outputTooLarge {
                terminateProcess()
                throw AgentClientCommandRunnerError.outputTooLarge
            }
        }
    }

    private var wasCancelled: Bool { lock.withLock { cancelled } }
    private var didTimeOut: Bool { lock.withLock { timedOut } }

    private func cancel() {
        let runningProcess: Process? = lock.withLock {
            cancelled = true
            return process
        }
        if let runningProcess { terminateAndScheduleForcedKill(runningProcess) }
    }

    private func markTimedOutAndTerminate() {
        let runningProcess: Process? = lock.withLock {
            guard !cancelled else { return nil }
            timedOut = true
            return process
        }
        if let runningProcess { terminateAndScheduleForcedKill(runningProcess) }
    }

    private func terminateProcess() {
        let runningProcess = lock.withLock { process }
        if let runningProcess { terminateAndScheduleForcedKill(runningProcess) }
    }

    private func terminateAndScheduleForcedKill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let processBox = AgentClientProcessBox(process)
        Task.detached(priority: .high) {
            try? await Task.sleep(for: Self.terminationGrace)
            guard processBox.process.isRunning else { return }
            _ = Darwin.kill(processBox.process.processIdentifier, SIGKILL)
        }
    }

    private func cleanup() {
        let openPipes: [Pipe] = lock.withLock {
            let value = pipes
            pipes = []
            process = nil
            return value
        }
        for pipe in openPipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}

private enum AgentClientOutputStream: Sendable {
    case stdout
    case stderr
}

private final class AgentClientOutputAccumulator: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data, to stream: AgentClientOutputStream) throws {
        try lock.withLock {
            guard stdout.count + stderr.count + data.count <= maximumBytes else {
                throw AgentClientCommandRunnerError.outputTooLarge
            }
            switch stream {
            case .stdout: stdout.append(data)
            case .stderr: stderr.append(data)
            }
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.withLock { (stdout, stderr) }
    }
}

private final class AgentClientProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

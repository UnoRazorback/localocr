import Foundation
import Darwin
import LocalOCRModelBridgeProtocol

public protocol ModelBridgeTransporting: Sendable {
    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse
}

public protocol ModelBridgeExecutableLocating: Sendable {
    func executableURL() throws -> URL
}

public enum ModelBridgeExecutableLocatorError: Error, Sendable, Equatable {
    case currentExecutableUnavailable
    case unsupportedExecutableLayout
    case helperNotFound
    case helperNotExecutable
    case unsafeHelperLocation
}

public struct RelativeModelBridgeExecutableLocator: ModelBridgeExecutableLocating {
    private let currentExecutableURL: URL?

    public init(currentExecutableURL: URL) {
        self.currentExecutableURL = currentExecutableURL
    }

    public init() {
        currentExecutableURL = Bundle.main.executableURL
    }

    public func executableURL() throws -> URL {
        guard let currentExecutableURL else {
            throw ModelBridgeExecutableLocatorError.currentExecutableUnavailable
        }

        let current = currentExecutableURL.standardizedFileURL
        let currentDirectory = current.deletingLastPathComponent()
        let allowedDirectory: URL
        if current.lastPathComponent == "LocalOCR Studio",
           currentDirectory.lastPathComponent == "MacOS",
           currentDirectory.deletingLastPathComponent().lastPathComponent == "Contents",
           currentDirectory.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" {
            allowedDirectory = currentDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
        } else if current.lastPathComponent == "localocr" || current.lastPathComponent == "localocr-mcp" {
            allowedDirectory = currentDirectory
        } else {
            throw ModelBridgeExecutableLocatorError.unsupportedExecutableLayout
        }

        let candidate = allowedDirectory
            .appendingPathComponent("localocr-model-bridge", isDirectory: false)
            .standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ModelBridgeExecutableLocatorError.helperNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw ModelBridgeExecutableLocatorError.helperNotExecutable
        }

        let resolvedAllowedDirectory = allowedDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.deletingLastPathComponent() == resolvedAllowedDirectory else {
            throw ModelBridgeExecutableLocatorError.unsafeHelperLocation
        }
        return candidate
    }
}

public enum ModelBridgeClientError: Error, Sendable, Equatable {
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case malformedResponse
    case responseIDMismatch(expected: UInt64, actual: UInt64)
    case helperLaunchFailed
    case helperExited(status: Int32)
    case timedOut
}

public actor StdioModelBridgeClient: ModelBridgeTransporting {
    private let executableLocator: any ModelBridgeExecutableLocating

    public init(executableLocator: any ModelBridgeExecutableLocating) {
        self.executableLocator = executableLocator
    }

    public init() {
        executableLocator = RelativeModelBridgeExecutableLocator()
    }

    public func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse {
        try Task.checkCancellation()
        var encodedRequest = try JSONEncoder().encode(request)
        guard encodedRequest.count <= ModelBridgeLimits.maximumMessageBytes else {
            throw ModelBridgeClientError.requestTooLarge
        }
        guard (try? JSONDecoder().decode(ModelBridgeRequest.self, from: encodedRequest)) != nil else {
            throw ModelBridgeClientError.invalidRequest
        }
        encodedRequest.append(10)
        let requestData = encodedRequest

        let executableURL = try executableLocator.executableURL()
        let execution = ModelBridgeProcessExecution(executableURL: executableURL)
        let timeout = Duration.milliseconds(request.timeoutMilliseconds)

        let responseData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await execution.execute(requestData: requestData)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ModelBridgeClientError.timedOut
            }

            defer {
                group.cancelAll()
            }
            guard let first = try await group.next() else {
                throw ModelBridgeClientError.helperLaunchFailed
            }
            return first
        }

        let lines = responseData.split(separator: 10, omittingEmptySubsequences: false)
        guard lines.count == 2, lines[1].isEmpty, !lines[0].isEmpty else {
            throw ModelBridgeClientError.malformedResponse
        }
        let response: ModelBridgeResponse
        do {
            response = try JSONDecoder().decode(ModelBridgeResponse.self, from: Data(lines[0]))
        } catch {
            throw ModelBridgeClientError.malformedResponse
        }
        guard response.id == request.id else {
            throw ModelBridgeClientError.responseIDMismatch(expected: request.id, actual: response.id)
        }
        guard Self.isValidResponseShape(response, for: request.action) else {
            throw ModelBridgeClientError.malformedResponse
        }
        return response
    }

    private static func isValidResponseShape(
        _ response: ModelBridgeResponse,
        for action: ModelBridgeAction
    ) -> Bool {
        if response.error != nil {
            return true
        }
        switch action {
        case .discover:
            return response.payloadJSON == nil && response.identity == nil
        case .status:
            return response.candidates.isEmpty
                && response.payloadJSON == nil
                && response.identity != nil
        case .generate:
            return response.candidates.isEmpty
                && response.payloadJSON != nil
                && response.identity != nil
        }
    }
}

private final class ModelBridgeProcessExecution: @unchecked Sendable {
    private static let terminationGrace = Duration.milliseconds(200)

    private let executableURL: URL
    private let lock = NSLock()
    private var process: Process?
    private var pipes: [Pipe] = []
    private var cancelled = false

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func execute(requestData: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            do {
                return try await run(requestData: requestData)
            } catch {
                if wasCancelled {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            cancel()
        }
    }

    private func run(requestData: Data) async throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics

        try lock.withLock {
            if cancelled {
                throw CancellationError()
            }
            self.process = process
            pipes = [input, output, diagnostics]
        }

        do {
            try process.run()
        } catch {
            cleanup()
            throw ModelBridgeClientError.helperLaunchFailed
        }

        let processBox = ProcessBox(process)
        let stdoutHandle = output.fileHandleForReading
        let stderrHandle = diagnostics.fileHandleForReading
        let stdoutTask = Task.detached { [self] in
            do {
                return try Self.readBoundedResponse(from: stdoutHandle)
            } catch {
                terminateProcess()
                throw error
            }
        }
        let stderrTask = Task.detached {
            Self.drainDiagnostics(from: stderrHandle)
        }
        let terminationTask = Task.detached {
            processBox.process.waitUntilExit()
            return processBox.process.terminationStatus
        }

        do {
            try input.fileHandleForWriting.write(contentsOf: requestData)
            try input.fileHandleForWriting.close()
        } catch {
            cancel()
            _ = await terminationTask.value
            cleanup()
            throw ModelBridgeClientError.helperLaunchFailed
        }

        let status = await terminationTask.value
        let responseResult = await stdoutTask.result
        _ = await stderrTask.value
        cleanup()
        try Task.checkCancellation()
        let response = try responseResult.get()
        guard status == 0 else {
            throw ModelBridgeClientError.helperExited(status: status)
        }
        return response
    }

    private var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func cancel() {
        let snapshot: (Process?, [Pipe]) = lock.withLock {
            cancelled = true
            return (process, pipes)
        }
        if let process = snapshot.0 {
            terminateAndScheduleForcedKill(process)
        }
        for pipe in snapshot.1 {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
    }

    private func terminateProcess() {
        let runningProcess = lock.withLock { process }
        if let runningProcess {
            terminateAndScheduleForcedKill(runningProcess)
        }
    }

    private func terminateAndScheduleForcedKill(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        let processBox = ProcessBox(process)
        Task.detached(priority: .high) {
            try? await Task.sleep(for: Self.terminationGrace)
            guard processBox.process.isRunning else {
                return
            }
            _ = Darwin.kill(processBox.process.processIdentifier, SIGKILL)
        }
    }

    private func cleanup() {
        let snapshot: [Pipe] = lock.withLock {
            let value = pipes
            pipes = []
            process = nil
            return value
        }
        for pipe in snapshot {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
    }

    private static func readBoundedResponse(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            let remaining = max(0, ModelBridgeLimits.maximumMessageBytes + 1 - data.count)
            let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
            if chunk.isEmpty {
                return data
            }
            data.append(chunk)
            if data.count > ModelBridgeLimits.maximumMessageBytes + 1 {
                throw ModelBridgeClientError.responseTooLarge
            }
        }
    }

    private static func drainDiagnostics(from handle: FileHandle) {
        while true {
            do {
                let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                if chunk.isEmpty {
                    return
                }
            } catch {
                return
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

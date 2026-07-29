import Foundation
import LocalOCRCore
import LocalOCRService

public struct CommandOutput: Sendable {
    public let stdout: @Sendable (String) -> Void
    public let stderr: @Sendable (String) -> Void

    public init(
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func json<Response: Encodable>(_ response: Response) {
        stdout(String(decoding: ResponseEncoding.encode(response), as: UTF8.self) + "\n")
    }

    func error(_ error: Error) {
        stderr("localocr: \(error.localizedDescription)\n")
    }

    func progress(_ progress: OCRProgress) {
        switch progress {
        case .inspecting:
            stderr("inspect\n")
        case let .recognizing(page, total):
            stderr("recognizing page \(page) of \(total)\n")
        case .assembling:
            stderr("assembling\n")
        case .completed:
            stderr("completed\n")
        }
    }

    func batchProgress(_ progress: BatchProgress) {
        stderr("[\(progress.currentItem)/\(progress.totalItems)] \(progress.sourcePath): ")
        self.progress(progress.progress)
    }

    func failedPages(_ pages: [Int]) {
        stderr("failed pages: \(pages.map(String.init).joined(separator: ", "))\n")
    }
}

enum CLIError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        }
    }
}

enum CLIExitCode: Int32 {
    case success = 0
    case operationFailure = 1
    case invalidArguments = 2
    case partialResult = 3
    case cancelled = 4
}

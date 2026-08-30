import Darwin
import Dispatch
import Foundation

public protocol LMStudioCLIProbing: Sendable {
    func linkStatus() async throws -> LMStudioLinkStatus
    func localModels() async throws -> [LMStudioLocalModel]
    func version() async throws -> String
}

public struct LMStudioLinkStatus: Sendable, Equatable {
    public let enabled: Bool
    public let connectedPeerCount: Int

    public init(enabled: Bool, connectedPeerCount: Int) {
        self.enabled = enabled
        self.connectedPeerCount = connectedPeerCount
    }
}

public struct LMStudioLocalModel: Sendable, Equatable {
    public let key: String
    public let selectedVariant: String?
    public let architecture: String?
    public let format: String
    public let quantization: String?
    public let sizeBytes: Int64

    public init(
        key: String,
        selectedVariant: String?,
        architecture: String?,
        format: String,
        quantization: String?,
        sizeBytes: Int64
    ) {
        self.key = key
        self.selectedVariant = selectedVariant
        self.architecture = architecture
        self.format = format
        self.quantization = quantization
        self.sizeBytes = sizeBytes
    }
}

public enum LMStudioCLIProbeError: Error, Sendable, Equatable {
    case missingExecutable
    case unsafeExecutable
    case invalidOutput
    case commandFailed
    case outputTooLarge
    case timedOut
}

public struct LMStudioCLIProbe: LMStudioCLIProbing, Sendable {
    static let maximumOutputBytes = 1_048_576

    private let homeDirectory: URL
    private let commandTimeout: Duration
    private let terminationGracePeriod: Duration

    public init() {
        homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        commandTimeout = .seconds(5)
        terminationGracePeriod = .milliseconds(250)
    }

    init(
        homeDirectory: URL,
        commandTimeout: Duration = .seconds(5),
        terminationGracePeriod: Duration = .milliseconds(250)
    ) {
        self.homeDirectory = homeDirectory
        self.commandTimeout = commandTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func linkStatus() async throws -> LMStudioLinkStatus {
        let data = try run(.linkStatus)
        let result: LinkStatusOutput
        do {
            result = try JSONDecoder().decode(LinkStatusOutput.self, from: data)
        } catch {
            throw LMStudioCLIProbeError.invalidOutput
        }

        let issues = Set(result.issues)
        guard issues.count == result.issues.count else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        let disabled = issues.contains(.deviceDisabled)
        let connectedPeerCount = result.peers.filter { $0.status == .connected }.count
        if disabled && (result.status != .offline || connectedPeerCount != 0) {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return LMStudioLinkStatus(
            enabled: !disabled,
            connectedPeerCount: connectedPeerCount
        )
    }

    public func localModels() async throws -> [LMStudioLocalModel] {
        let data = try run(.localModels)
        let models: [LocalModelOutput]
        do {
            models = try JSONDecoder().decode([LocalModelOutput].self, from: data)
        } catch {
            throw LMStudioCLIProbeError.invalidOutput
        }

        guard models.allSatisfy(\.hasBoundedIdentity) else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return models.compactMap { model in
            guard model.deviceIdentifier == nil else { return nil }
            return LMStudioLocalModel(
                key: model.modelKey,
                selectedVariant: model.selectedVariant,
                architecture: model.architecture,
                format: model.format,
                quantization: model.quantization?.name,
                sizeBytes: model.sizeBytes
            )
        }
    }

    public func version() async throws -> String {
        let data = try run(.version)
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
        guard validIdentityString(version) else {
            throw LMStudioCLIProbeError.invalidOutput
        }
        return version
    }

    private func run(_ command: Command) throws -> Data {
        let executable = try resolvedExecutable()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutCollector = BoundedProcessOutput(limit: Self.maximumOutputBytes)
        let stderrCollector = BoundedProcessOutput(limit: Self.maximumOutputBytes)
        let readers = DispatchGroup()
        let completion = DispatchSemaphore(value: 0)

        process.executableURL = executable
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in completion.signal() }

        Self.startReader(
            stdout.fileHandleForReading,
            collector: stdoutCollector,
            group: readers
        )
        Self.startReader(
            stderr.fileHandleForReading,
            collector: stderrCollector,
            group: readers
        )

        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            throw LMStudioCLIProbeError.commandFailed
        }

        let completed = completion.wait(timeout: Self.deadline(after: commandTimeout)) == .success
        if !completed {
            process.terminate()
            if completion.wait(timeout: Self.deadline(after: terminationGracePeriod)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                completion.wait()
            }
        }
        process.waitUntilExit()
        readers.wait()

        if !completed {
            throw LMStudioCLIProbeError.timedOut
        }
        guard !stdoutCollector.exceededLimit,
              !stderrCollector.exceededLimit else {
            throw LMStudioCLIProbeError.outputTooLarge
        }
        guard !stdoutCollector.readFailed,
              !stderrCollector.readFailed,
              process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw LMStudioCLIProbeError.commandFailed
        }
        return stdoutCollector.data
    }

    private func resolvedExecutable() throws -> URL {
        let logicalBin = homeDirectory
            .appendingPathComponent(".lmstudio", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let logicalExecutable = logicalBin.appendingPathComponent("lms", isDirectory: false)
        guard FileManager.default.fileExists(atPath: logicalExecutable.path) else {
            throw LMStudioCLIProbeError.missingExecutable
        }

        let physicalBin = logicalBin.resolvingSymlinksInPath().standardizedFileURL
        let physicalExecutable = logicalExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard physicalExecutable.deletingLastPathComponent() == physicalBin else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: physicalExecutable.path)
        } catch {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() || owner.uint32Value == 0,
              FileManager.default.isExecutableFile(atPath: physicalExecutable.path) else {
            throw LMStudioCLIProbeError.unsafeExecutable
        }
        return physicalExecutable
    }

    private static func startReader(
        _ handle: FileHandle,
        collector: BoundedProcessOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    collector.append(chunk)
                }
            } catch {
                collector.markReadFailed()
            }
        }
    }

    private static func deadline(after duration: Duration) -> DispatchTime {
        let components = duration.components
        let millisecondsPerSecond: Int64 = 1_000
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let milliseconds = components.seconds * millisecondsPerSecond
            + max(1, components.attoseconds / attosecondsPerMillisecond)
        return .now() + .milliseconds(Int(clamping: milliseconds))
    }

    private func validIdentityString(_ value: String) -> Bool {
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

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storedData = Data()
    private var limitExceeded = false
    private var failed = false

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { storedData }
    }

    var exceededLimit: Bool {
        lock.withLock { limitExceeded }
    }

    var readFailed: Bool {
        lock.withLock { failed }
    }

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
    enum Status: String, Decodable {
        case offline, starting, online, stopping
    }

    enum Issue: String, Decodable {
        case deviceDisabled, notLoggedIn, noAccess, badVersion
    }

    struct Peer: Decodable {
        enum Status: String, Decodable {
            case connected, disconnected
        }

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
            && [modelKey, format, displayName, publisher, path, indexedModelIdentifier].allSatisfy {
                !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && $0.utf8.count <= 4_096
            }
            && (architecture.map { !$0.isEmpty && $0.utf8.count <= 4_096 } ?? true)
            && (quantization.map { !$0.name.isEmpty && $0.name.utf8.count <= 4_096 && $0.bits > 0 } ?? true)
            && (selectedVariant.map { !$0.isEmpty && $0.utf8.count <= 4_096 } ?? true)
            && (variants?.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4_096 } ?? true)
            && maxContextLength > 0
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(
    in decoder: any Decoder,
    allowed: [String]
) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown keys are not allowed.")
        )
    }
}

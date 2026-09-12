import Foundation

private enum TopLevelJSONMemberValidator {
    enum Result {
        case valid
        case duplicateMember
        case malformed
    }

    static func validate(_ data: Data) -> Result {
        var parser = Parser(data: data)
        parser.skipWhitespace()
        guard parser.parseValue(isTopLevelObject: true) else {
            return .malformed
        }
        parser.skipWhitespace()
        guard parser.index == data.count else {
            return .malformed
        }
        return parser.hasDuplicateTopLevelMember ? .duplicateMember : .valid
    }

    private struct Parser {
        let data: Data
        var index = 0
        var hasDuplicateTopLevelMember = false

        mutating func parseValue(isTopLevelObject: Bool = false) -> Bool {
            skipWhitespace()
            guard index < data.count else { return false }

            switch data[index] {
            case 0x7B:
                return parseObject(isTopLevel: isTopLevelObject)
            case 0x5B:
                return parseArray()
            case 0x22:
                return parseString() != nil
            case 0x74:
                return parseLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66:
                return parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case 0x6E:
                return parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
            case 0x2D, 0x30...0x39:
                return parseNumber()
            default:
                return false
            }
        }

        mutating func parseObject(isTopLevel: Bool) -> Bool {
            guard consume(0x7B) else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }

            var memberNames = Set<String>()
            while true {
                guard let memberName = parseString() else { return false }
                if isTopLevel, !memberNames.insert(memberName).inserted {
                    hasDuplicateTopLevelMember = true
                }
                skipWhitespace()
                guard consume(0x3A), parseValue() else { return false }
                skipWhitespace()
                if consume(0x7D) { return true }
                guard consume(0x2C) else { return false }
                skipWhitespace()
            }
        }

        mutating func parseArray() -> Bool {
            guard consume(0x5B) else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }

            while true {
                guard parseValue() else { return false }
                skipWhitespace()
                if consume(0x5D) { return true }
                guard consume(0x2C) else { return false }
            }
        }

        mutating func parseString() -> String? {
            let start = index
            guard consume(0x22) else { return nil }

            while index < data.count {
                let byte = data[index]
                index += 1
                if byte == 0x22 {
                    return try? JSONDecoder().decode(String.self, from: Data(data[start..<index]))
                }
                guard byte >= 0x20 else { return nil }
                guard byte == 0x5C else { continue }
                guard index < data.count else { return nil }
                let escape = data[index]
                index += 1
                switch escape {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    continue
                case 0x75:
                    guard consumeHexDigit(), consumeHexDigit(), consumeHexDigit(), consumeHexDigit() else {
                        return nil
                    }
                default:
                    return nil
                }
            }
            return nil
        }

        mutating func parseLiteral(_ bytes: [UInt8]) -> Bool {
            guard index + bytes.count <= data.count,
                  data[index..<(index + bytes.count)].elementsEqual(bytes)
            else { return false }
            index += bytes.count
            return true
        }

        mutating func parseNumber() -> Bool {
            _ = consume(0x2D)
            guard index < data.count else { return false }
            if consume(0x30) {
                // A leading zero is the whole integer part.
            } else {
                guard consumeDigit() else { return false }
                while consumeDigit() {}
            }
            if consume(0x2E) {
                guard consumeDigit() else { return false }
                while consumeDigit() {}
            }
            if consume(0x45) || consume(0x65) {
                _ = consume(0x2B) || consume(0x2D)
                guard consumeDigit() else { return false }
                while consumeDigit() {}
            }
            return true
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < data.count, data[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func consumeDigit() -> Bool {
            guard index < data.count, (0x30...0x39).contains(data[index]) else { return false }
            index += 1
            return true
        }

        mutating func consumeHexDigit() -> Bool {
            guard index < data.count else { return false }
            let byte = data[index]
            guard (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) else {
                return false
            }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < data.count, [0x09, 0x0A, 0x0D, 0x20].contains(data[index]) {
                index += 1
            }
        }
    }
}

public struct LocalAIActivityRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let activityID: UUID
    public let producerID: String
    public let producerRole: LocalAIProducerRole
    public let platform: LocalAIPlatform
    public let runtimeFamily: LocalAIRuntimeFamily
    public let runtimeIdentifier: String?
    public let route: LocalAIRoute
    public let operation: LocalAIOperation
    public let productTask: LocalAIProductTask?
    public let state: LocalAIActivityState
    public let startedAt: Date
    public let heartbeatAt: Date
    public let expiresAt: Date
    public let endedAt: Date?
    public let outcome: LocalAIActivityOutcome?
    public let evidence: LocalAIEvidence

    public init(
        schemaVersion: Int,
        activityID: UUID,
        producerID: String,
        producerRole: LocalAIProducerRole,
        platform: LocalAIPlatform,
        runtimeFamily: LocalAIRuntimeFamily,
        runtimeIdentifier: String?,
        route: LocalAIRoute,
        operation: LocalAIOperation,
        productTask: LocalAIProductTask?,
        state: LocalAIActivityState,
        startedAt: Date,
        heartbeatAt: Date,
        expiresAt: Date,
        endedAt: Date?,
        outcome: LocalAIActivityOutcome?,
        evidence: LocalAIEvidence
    ) {
        self.schemaVersion = schemaVersion
        self.activityID = activityID
        self.producerID = producerID
        self.producerRole = producerRole
        self.platform = platform
        self.runtimeFamily = runtimeFamily
        self.runtimeIdentifier = runtimeIdentifier
        self.route = route
        self.operation = operation
        self.productTask = productTask
        self.state = state
        self.startedAt = startedAt
        self.heartbeatAt = heartbeatAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case activityID = "activity_id"
        case producerID = "producer_id"
        case producerRole = "producer_role"
        case platform
        case runtimeFamily = "runtime_family"
        case runtimeIdentifier = "runtime_identifier"
        case route
        case operation
        case productTask = "product_task"
        case state
        case startedAt = "started_at"
        case heartbeatAt = "heartbeat_at"
        case expiresAt = "expires_at"
        case endedAt = "ended_at"
        case outcome
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            activityID: try container.decode(UUID.self, forKey: .activityID),
            producerID: try container.decode(String.self, forKey: .producerID),
            producerRole: try container.decode(LocalAIProducerRole.self, forKey: .producerRole),
            platform: try container.decode(LocalAIPlatform.self, forKey: .platform),
            runtimeFamily: try container.decode(LocalAIRuntimeFamily.self, forKey: .runtimeFamily),
            runtimeIdentifier: try container.decode(String?.self, forKey: .runtimeIdentifier),
            route: try container.decode(LocalAIRoute.self, forKey: .route),
            operation: try container.decode(LocalAIOperation.self, forKey: .operation),
            productTask: try container.decode(LocalAIProductTask?.self, forKey: .productTask),
            state: try container.decode(LocalAIActivityState.self, forKey: .state),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            heartbeatAt: try container.decode(Date.self, forKey: .heartbeatAt),
            expiresAt: try container.decode(Date.self, forKey: .expiresAt),
            endedAt: try container.decode(Date?.self, forKey: .endedAt),
            outcome: try container.decode(LocalAIActivityOutcome?.self, forKey: .outcome),
            evidence: try container.decode(LocalAIEvidence.self, forKey: .evidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(activityID, forKey: .activityID)
        try container.encode(producerID, forKey: .producerID)
        try container.encode(producerRole, forKey: .producerRole)
        try container.encode(platform, forKey: .platform)
        try container.encode(runtimeFamily, forKey: .runtimeFamily)
        try container.encode(runtimeIdentifier, forKey: .runtimeIdentifier)
        try container.encode(route, forKey: .route)
        try container.encode(operation, forKey: .operation)
        try container.encode(productTask, forKey: .productTask)
        try container.encode(state, forKey: .state)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(heartbeatAt, forKey: .heartbeatAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(evidence, forKey: .evidence)
    }
}

public enum LocalAIProducerRole: String, Codable, Sendable, CaseIterable {
    case studio, mcp, cli
    case iosApp = "ios_app"
}

public enum LocalAIPlatform: String, Codable, Sendable, CaseIterable {
    case macos, ios, ipados
}

public enum LocalAIRuntimeFamily: String, Codable, Sendable, CaseIterable {
    case foundationModels = "foundation_models"
    case coreML = "core_ml"
    case mlx
    case localRuntime = "local_runtime"
}

public enum LocalAIRoute: String, Codable, Sendable, CaseIterable {
    case onDevice = "on_device"
    case onDeviceLoopback = "on_device_loopback"
}

public enum LocalAIOperation: String, Codable, Sendable, CaseIterable {
    case generation, inference, embedding, training
    case fineTuning = "fine_tuning"
}

public enum LocalAIProductTask: String, Codable, Sendable, CaseIterable {
    case summarize, organize, extract
}

public enum LocalAIActivityState: String, Codable, Sendable, CaseIterable {
    case active, ended
}

public enum LocalAIActivityOutcome: String, Codable, Sendable, CaseIterable {
    case success, cancelled, failure
}

public enum LocalAIEvidence: String, Codable, Sendable, CaseIterable {
    case participatingAppReported = "participating_app_reported"
}

public struct LocalAIActivityDescriptor: Sendable, Equatable {
    public let producerID: String
    public let producerRole: LocalAIProducerRole
    public let platform: LocalAIPlatform
    public let runtimeFamily: LocalAIRuntimeFamily
    public let runtimeIdentifier: String?
    public let route: LocalAIRoute
    public let operation: LocalAIOperation
    public let productTask: LocalAIProductTask?

    init(
        producerID: String,
        producerRole: LocalAIProducerRole,
        platform: LocalAIPlatform,
        runtimeFamily: LocalAIRuntimeFamily,
        runtimeIdentifier: String?,
        route: LocalAIRoute,
        operation: LocalAIOperation,
        productTask: LocalAIProductTask?
    ) {
        self.producerID = producerID
        self.producerRole = producerRole
        self.platform = platform
        self.runtimeFamily = runtimeFamily
        self.runtimeIdentifier = runtimeIdentifier
        self.route = route
        self.operation = operation
        self.productTask = productTask
    }

    public static func foundationModels(
        role: LocalAIProducerRole,
        platform: LocalAIPlatform = .macos,
        task: LocalAIProductTask
    ) -> Self {
        .init(
            producerID: LocalAIActivityContract.localOCRProducerID,
            producerRole: role,
            platform: platform,
            runtimeFamily: .foundationModels,
            runtimeIdentifier: LocalAIActivityContract.foundationModelsIdentifier,
            route: .onDevice,
            operation: .generation,
            productTask: task
        )
    }

    public static func localRuntime(
        role: LocalAIProducerRole,
        platform: LocalAIPlatform,
        task: LocalAIProductTask
    ) -> Self {
        .init(
            producerID: LocalAIActivityContract.localOCRProducerID,
            producerRole: role,
            platform: platform,
            runtimeFamily: .localRuntime,
            runtimeIdentifier: nil,
            route: .onDeviceLoopback,
            operation: .generation,
            productTask: task
        )
    }
}

public enum LocalAIActivityContract {
    public static let schemaVersion = 1
    public static let maximumRecordBytes = 16_384
    public static let localOCRProducerID = "com.rayconsulting.localocr"
    public static let foundationModelsIdentifier = "SystemLanguageModel.default"

    static let v1Keys: Set<String> = [
        "schema_version", "activity_id", "producer_id", "producer_role", "platform",
        "runtime_family", "runtime_identifier", "route", "operation", "product_task",
        "state", "started_at", "heartbeat_at", "expires_at", "ended_at", "outcome",
        "evidence",
    ]
    private static let activeLease: TimeInterval = 45
    private static let recentRetention: TimeInterval = 24 * 60 * 60
    private static let dateFormatter = CanonicalTimestampFormatter()

    public static func encode(_ record: LocalAIActivityRecord) throws -> Data {
        try validate(record)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, container in
            var value = container.singleValueContainer()
            try value.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var data = try encoder.encode(record)
        data.append(0x0A)
        guard data.count <= maximumRecordBytes else {
            throw LocalAIActivityContractError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> LocalAIActivityRecord {
        guard data.count <= maximumRecordBytes else {
            throw LocalAIActivityContractError.oversized
        }

        switch TopLevelJSONMemberValidator.validate(data) {
        case .valid:
            break
        case .duplicateMember:
            throw LocalAIActivityContractError.unexpectedKeys
        case .malformed:
            throw LocalAIActivityContractError.malformedJSON
        }

        let rawObject: [String: JSONValue]
        do {
            rawObject = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw LocalAIActivityContractError.malformedJSON
        }
        guard Set(rawObject.keys) == v1Keys else {
            throw LocalAIActivityContractError.unexpectedKeys
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = dateFormatter.date(from: value), dateFormatter.string(from: date) == value else {
                throw LocalAIActivityContractError.invalidTimestamp
            }
            return date
        }

        let record: LocalAIActivityRecord
        do {
            record = try decoder.decode(LocalAIActivityRecord.self, from: data)
        } catch let error as LocalAIActivityContractError {
            throw error
        } catch is DecodingError {
            throw LocalAIActivityContractError.invalidEnum
        } catch {
            throw LocalAIActivityContractError.malformedJSON
        }

        try validate(record)
        return record
    }

    private static func validate(_ record: LocalAIActivityRecord) throws {
        guard record.schemaVersion == schemaVersion else {
            throw LocalAIActivityContractError.unsupportedVersion
        }
        guard record.producerID == localOCRProducerID, isSafeRegisteredIdentifier(record.producerID) else {
            throw LocalAIActivityContractError.invalidIdentifier
        }
        switch record.runtimeFamily {
        case .foundationModels:
            guard record.runtimeIdentifier == foundationModelsIdentifier else {
                throw LocalAIActivityContractError.invalidIdentifier
            }
        case .coreML, .mlx, .localRuntime:
            guard record.runtimeIdentifier == nil else {
                throw LocalAIActivityContractError.invalidIdentifier
            }
        }
        if let runtimeIdentifier = record.runtimeIdentifier, !isSafeRegisteredIdentifier(runtimeIdentifier) {
            throw LocalAIActivityContractError.invalidIdentifier
        }
        guard hasWholeSecondPrecision(record.startedAt),
              hasWholeSecondPrecision(record.heartbeatAt),
              hasWholeSecondPrecision(record.expiresAt),
              record.endedAt.map(hasWholeSecondPrecision) ?? true
        else {
            throw LocalAIActivityContractError.invalidTimestamp
        }

        switch record.state {
        case .active:
            guard record.endedAt == nil,
                  record.outcome == nil,
                  record.startedAt <= record.heartbeatAt,
                  record.heartbeatAt < record.expiresAt,
                  record.expiresAt == record.heartbeatAt.addingTimeInterval(activeLease)
            else {
                throw LocalAIActivityContractError.invalidState
            }
        case .ended:
            guard let endedAt = record.endedAt,
                  record.outcome != nil,
                  record.startedAt <= record.heartbeatAt,
                  record.heartbeatAt <= endedAt,
                  endedAt < record.expiresAt,
                  record.expiresAt == endedAt.addingTimeInterval(recentRetention)
            else {
                throw LocalAIActivityContractError.invalidState
            }
        }
    }

    private static func isSafeRegisteredIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains(":")
            && !value.contains("..")
    }

    private static func hasWholeSecondPrecision(_ date: Date) -> Bool {
        date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970
    }
}

public enum LocalAIActivityContractError: Error, Sendable, Equatable {
    case oversized
    case malformedJSON
    case unexpectedKeys
    case unsupportedVersion
    case invalidIdentifier
    case invalidEnum
    case invalidTimestamp
    case invalidState
}

private enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

private final class CanonicalTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: value)
    }
}

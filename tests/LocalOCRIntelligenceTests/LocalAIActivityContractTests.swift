@testable import LocalOCRIntelligence
import Foundation
import Testing

@Suite struct LocalAIActivityContractTests {
    // Catches a missing or incorrectly mapped canonical field, date, or canonical encoder configuration.
    @Test func canonicalFixtureDecodesAndReencodesByteForByte() throws {
        let fixtureData = try Data(contentsOf: try #require(Bundle.module.url(
            forResource: "localocr-foundation-models-active",
            withExtension: "json",
            subdirectory: "Fixtures/LocalAIActivity/v1"
        )))

        let record = try LocalAIActivityContract.decode(fixtureData)

        #expect(record.schemaVersion == 1)
        #expect(record.activityID.uuidString == "11111111-1111-4111-8111-111111111111")
        #expect(record.producerID == "com.rayconsulting.localocr")
        #expect(record.producerRole == .studio)
        #expect(record.platform == .macos)
        #expect(record.runtimeFamily == .foundationModels)
        #expect(record.runtimeIdentifier == "SystemLanguageModel.default")
        #expect(record.route == .onDevice)
        #expect(record.operation == .generation)
        #expect(record.productTask == .summarize)
        #expect(record.state == .active)
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_788_184_800))
        #expect(record.heartbeatAt == Date(timeIntervalSince1970: 1_788_184_800))
        #expect(record.expiresAt == Date(timeIntervalSince1970: 1_788_184_845))
        #expect(record.endedAt == nil)
        #expect(record.outcome == nil)
        #expect(record.evidence == .participatingAppReported)
        #expect(try LocalAIActivityContract.encode(record) == fixtureData)
    }

    // Catches an encoder or decoder that drops a registered v1 enum case.
    @Test func decoderAcceptsEveryAllowlistedEnumValue() throws {
        for role in ["studio", "mcp", "cli", "ios_app"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [("studio", role)]))
        }
        for platform in ["macos", "ios", "ipados"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [("macos", platform)]))
        }
        for route in ["on_device", "on_device_loopback"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [("on_device", route)]))
        }
        for operation in ["generation", "inference", "embedding", "training", "fine_tuning"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [("generation", operation)]))
        }
        for task in ["summarize", "organize", "extract"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [("summarize", task)]))
        }
        for family in ["core_ml", "mlx", "local_runtime"] {
            _ = try LocalAIActivityContract.decode(activeData(replacing: [
                ("foundation_models", family),
                ("\"runtime_identifier\":\"SystemLanguageModel.default\"", "\"runtime_identifier\":null")
            ]))
        }
        for outcome in ["success", "cancelled", "failure"] {
            _ = try LocalAIActivityContract.decode(endedData(outcome: outcome))
        }
        _ = try LocalAIActivityContract.decode(endedData(outcome: "success"))
    }

    // Catches descriptor factories that expose an arbitrary Foundation Models identifier or unsafe default route.
    @Test func foundationModelsDescriptorUsesOnlyRegisteredIdentity() {
        let descriptor = LocalAIActivityDescriptor.foundationModels(role: .mcp, task: .extract)

        #expect(descriptor.producerID == "com.rayconsulting.localocr")
        #expect(descriptor.producerRole == .mcp)
        #expect(descriptor.platform == .macos)
        #expect(descriptor.runtimeFamily == .foundationModels)
        #expect(descriptor.runtimeIdentifier == "SystemLanguageModel.default")
        #expect(descriptor.route == .onDevice)
        #expect(descriptor.operation == .generation)
        #expect(descriptor.productTask == .extract)
    }

    // Catches permissive key-set decoding that would accept future or content-bearing fields.
    @Test func decoderRejectsUnknownKey() {
        let bad = Data(#"{"schema_version":1,"unexpected":"content"}"#.utf8)

        #expect(throws: LocalAIActivityContractError.self) {
            try LocalAIActivityContract.decode(bad)
        }
    }

    @Test func decoderRejectsEveryDuplicateTopLevelMember() throws {
        let duplicateMembers = [
            (#"\u0073chema_version"#, "1"),
            ("activity_id", #""22222222-2222-4222-8222-222222222222""#),
            ("producer_id", #""com.rayconsulting.localocr""#),
            ("producer_role", #""studio""#),
            ("platform", #""macos""#),
            ("runtime_family", #""foundation_models""#),
            ("runtime_identifier", #""secret-second""#),
            ("route", #""on_device""#),
            ("operation", #""generation""#),
            ("product_task", #""summarize""#),
            ("state", #""active""#),
            ("started_at", #""2026-08-31T14:00:00Z""#),
            ("heartbeat_at", #""2026-08-31T14:00:00Z""#),
            ("expires_at", #""2026-08-31T14:00:45Z""#),
            ("ended_at", "null"),
            ("outcome", "null"),
            ("evidence", #""participating_app_reported""#)
        ]

        for (key, value) in duplicateMembers {
            #expect(throws: LocalAIActivityContractError.self) {
                try LocalAIActivityContract.decode(try dataByAppendingDuplicateMember(key: key, value: value))
            }
        }
    }

    // Catches decoder paths that accept unsupported schemas or malformed/unsafe producer metadata.
    @Test func decoderRejectsUnsupportedOrUnsafeIdentifiers() {
        let invalidRecords = [
            activeData(replacing: [("\"schema_version\":1", "\"schema_version\":2")]),
            activeData(replacing: [("11111111-1111-4111-8111-111111111111", "not-a-uuid")]),
            activeData(replacing: [("SystemLanguageModel.default", "../../private-model")]),
            activeData(replacing: [("SystemLanguageModel.default", "https://example.com/model")]),
            activeData(replacing: [("com.rayconsulting.localocr", "com.example.unregistered")])
        ]

        for data in invalidRecords {
            #expect(throws: LocalAIActivityContractError.self) {
                try LocalAIActivityContract.decode(data)
            }
        }
    }

    // Catches lifecycle validation that permits an active record to disclose an outcome or an ended record without one.
    @Test func decoderRejectsRecordsThatViolateStateInvariants() {
        let invalidRecords = [
            activeData(replacing: [("\"outcome\":null", "\"outcome\":\"success\"")]),
            endedData(outcome: nil)
        ]

        for data in invalidRecords {
            #expect(throws: LocalAIActivityContractError.self) {
                try LocalAIActivityContract.decode(data)
            }
        }
    }
}

private func activeData(replacing replacements: [(String, String)] = []) -> Data {
    var json = #"{"activity_id":"11111111-1111-4111-8111-111111111111","ended_at":null,"evidence":"participating_app_reported","expires_at":"2026-08-31T14:00:45Z","heartbeat_at":"2026-08-31T14:00:00Z","operation":"generation","outcome":null,"platform":"macos","producer_id":"com.rayconsulting.localocr","producer_role":"studio","product_task":"summarize","route":"on_device","runtime_family":"foundation_models","runtime_identifier":"SystemLanguageModel.default","schema_version":1,"started_at":"2026-08-31T14:00:00Z","state":"active"}"#
    for (source, replacement) in replacements {
        json = json.replacingOccurrences(of: source, with: replacement)
    }
    return Data(json.utf8)
}

private func endedData(outcome: String?) -> Data {
    let outcomeJSON = outcome.map { "\"\($0)\"" } ?? "null"
    return Data(#"{"activity_id":"11111111-1111-4111-8111-111111111111","ended_at":"2026-08-31T14:00:01Z","evidence":"participating_app_reported","expires_at":"2026-09-01T14:00:01Z","heartbeat_at":"2026-08-31T14:00:00Z","operation":"generation","outcome":\#(outcomeJSON),"platform":"macos","producer_id":"com.rayconsulting.localocr","producer_role":"studio","product_task":"summarize","route":"on_device","runtime_family":"foundation_models","runtime_identifier":"SystemLanguageModel.default","schema_version":1,"started_at":"2026-08-31T14:00:00Z","state":"ended"}"#.utf8)
}

private func dataByAppendingDuplicateMember(key: String, value: String) throws -> Data {
    let canonical = try Data(contentsOf: try #require(Bundle.module.url(
        forResource: "localocr-foundation-models-active",
        withExtension: "json",
        subdirectory: "Fixtures/LocalAIActivity/v1"
    )))
    let closingBrace = try #require(canonical.lastIndex(of: 0x7D))
    var mutated = Data(canonical[..<closingBrace])
    mutated.append(Data(",\"\(key)\":\(value)".utf8))
    mutated.append(canonical[closingBrace...])
    return mutated
}

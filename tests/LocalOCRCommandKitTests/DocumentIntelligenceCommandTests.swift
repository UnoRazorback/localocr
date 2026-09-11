import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import LocalOCRMCP
import LocalOCRModelBridgeProtocol
import MCPStdio
@testable import LocalOCRCommandKit
import Testing

@Suite struct DocumentIntelligenceCommandTests {
    @Test func oneShotCommandsEmitOneJSONWithSourceAndActualProvenance() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for command in ["summarize", "organize", "extract-fields"] {
            let capture = IntelligenceCapture()
            let provider = OneShotProvider()
            let app = CLIApplication(service: FixtureService(), output: capture.output,
                                     textLoader: OneShotLoader(), intelligence: provider)
            let args = [command, file.path, "--json"] + (command == "extract-fields" ? ["--field", " total "] : [])
            #expect(await app.run(arguments: args) == 0)
            let values = capture.read()
            #expect(values.count == 1)
            var object = try #require(JSONSerialization.jsonObject(with: Data(values[0].utf8)) as? [String: Any])
            #expect(object["source_path"] as? String == file.path)
            #expect(object["source_sha256"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            let model = try #require(object["local_model"] as? [String: Any])
            #expect(model["provider_id"] as? String == "ollama")
            #expect(model["model"] as? String == "fixture")
            #expect(model["harness_version"] as? String == "1.0")
            #expect(Set(model.keys) == Set(["provider_id", "provider_display_name", "model", "processing", "fingerprint", "harness_version", "qualified_at"]))
            if command == "extract-fields" { #expect(await provider.names == ["total"]) }
            let toolName = ["summarize": "summarize_document", "organize": "organize_document", "extract-fields": "extract_document_fields"][command]!
            let dispatcher = MCPToolDispatcher(service: FixtureService(), textLoader: OneShotLoader(), intelligence: provider, consentStore: OneShotConsent(), currentDirectory: file.deletingLastPathComponent())
            var mcpArgs: [String: Value] = ["file_path": .string(file.path)]
            if command == "extract-fields" { mcpArgs["fields"] = .array([.string("total")]) }
            let result = await dispatcher.callTool(name: toolName, arguments: mcpArgs)
            let content = try #require(result.content.first)
            guard case let .text(text, _, _) = content else { Issue.record("Expected JSON text"); continue }
            let mcpObject = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            object.removeValue(forKey: "source_path")
            object.removeValue(forKey: "source_sha256")
            #expect(NSDictionary(dictionary: object).isEqual(to: mcpObject))

        }
    }

    @Test func sharedPDFLoaderUsesNativeFirstServiceDefaults() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = FixtureService()
        let capture = IntelligenceCapture()
        let app = CLIApplication(service: service, output: capture.output, intelligence: OneShotProvider())
        #expect(await app.run(arguments: ["summarize", file.path, "--json"]) == 0)
        let request = try #require(await service.recorder.lastOCRRequest())
        #expect(request.fileURL == file)
        #expect(request.forceOCR == false)
        #expect(request.includeLines == false)
    }

    @Test func invalidFieldsFailBeforeLoadingAndProduceNoStdout() async {
        for fields in [[], [" "], ["a", " a "], [String(repeating: "a", count: 129)], (1...33).map(String.init)] {
            let capture = IntelligenceCapture()
            let app = CLIApplication(service: FixtureService(), output: capture.output,
                                     textLoader: OneShotLoader(), intelligence: OneShotProvider())
            let args = ["extract-fields", "/missing.pdf", "--json"] + fields.flatMap { ["--field", $0] }
            #expect(await app.run(arguments: args) == 2)
            #expect(capture.read().isEmpty)
        }
    }

    @Test func maximumFieldCountAndLengthAreAccepted() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let names = [String(repeating: "x", count: 128)] + (1...31).map(String.init)
        let provider = OneShotProvider()
        let app = CLIApplication(service: FixtureService(), output: IntelligenceCapture().output, textLoader: OneShotLoader(), intelligence: provider)
        #expect(await app.run(arguments: ["extract-fields", file.path, "--json"] + names.flatMap { ["--field", $0] }) == 0)
        #expect(await provider.names == names)
    }

    @Test func missingStaleAndUnavailableSelectionsFailWithoutFallback() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = LocalModelIdentity(provider: .ollama, model: "fixture", fingerprint: "hash", harnessVersion: "1.0")
        let states: [(LocalIntelligenceSelectionState, String)] = [
            (.none, "selection_corrupt"),
            (.selected(.external(identity: identity, qualification: .init(policyVersion: 0, fixtureVersion: LocalModelQualificationReceipt.currentFixtureVersion, identity: identity, passedActions: Set(LocalIntelligenceAction.allCases), qualifiedAt: Date()), acknowledgment: .init(policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion, identity: identity, acceptedAt: Date()))), "qualification_required"),
            (.invalid(.modelUnavailable(identity)), "model_unavailable"),
            (.invalid(.acknowledgmentRequired(identity)), "acknowledgment_required")
        ]
        for (state, code) in states {
            for command in ["summarize", "organize", "extract-fields"] {
                let capture = IntelligenceCapture()
                let transport = OneShotTransport()
                let apple = OneShotProvider()
                let router = LocalIntelligenceProviderRouter(selectionStore: OneShotSelection(stateValue: state), transport: transport, appleProviderFactory: { apple })
                let app = CLIApplication(service: FixtureService(), output: capture.output, textLoader: OneShotLoader(), intelligence: router)
                let args = [command, file.path, "--json"] + (command == "extract-fields" ? ["--field", "total"] : [])
                #expect(await app.run(arguments: args) == 2)
                #expect(capture.read().isEmpty)
                #expect(capture.readErrors() == "error: \(code)\n")
                #expect(await transport.calls == 0)
                #expect(await apple.calls == 0)
            }
        }
    }

    @Test func providerFailuresPreserveExitAndNeverEmitPartialJSON() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for (failure, exit): (IntelligenceError, Int32) in [(.malformedOutput, 1), (.cancelled, 4), (.selection(.corruptReceipt), 2)] {
            let capture = IntelligenceCapture()
            let app = CLIApplication(service: FixtureService(), output: capture.output,
                                     textLoader: OneShotLoader(), intelligence: OneShotProvider(failure: failure))
            #expect(await app.run(arguments: ["summarize", file.path, "--json"]) == exit)
            #expect(capture.read().isEmpty)
        }
    }
}

private struct OneShotLoader: DocumentTextLoading {
    func load(_ sourceURL: URL) async throws -> IntelligenceDocument {
        IntelligenceDocument(pages: [.init(number: 1, text: "Total: 12")])
    }
}
private actor OneShotProvider: DocumentIntelligenceProviding {
    var availability: IntelligenceAvailability { .available }
    var names: [String] = []
    var calls = 0
    let failure: IntelligenceError?
    init(failure: IntelligenceError? = nil) { self.failure = failure }
    let model = LocalModelProvenance(provider: .ollama, providerDisplayName: "Ollama", model: "fixture", processing: .onDeviceLoopback, fingerprint: "sha256:fixture", qualifiedAt: nil, harnessVersion: "1.0")
    func summarize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        calls += 1
        if let failure { throw failure }
        return .init(value: .init(text: "Total 12", citations: [.init(page: 1, quote: "Total: 12")]), model: model)
    }
    func organize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        calls += 1
        return .init(value: .init(title: "Bill", category: "Finance", tags: [], citations: []), model: model)
    }
    func extract(_ names: [String], from document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        calls += 1
        self.names = names
        return .init(value: names.map { .init(name: $0, value: nil, sourcePage: nil, evidence: nil) }, model: model)
    }
}
private final class IntelligenceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var errors = ""
    var output: CommandOutput { .init(stdout: { self.append($0) }, stderr: { self.appendError($0) }) }
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func read() -> [String] { lock.withLock { values } }
    func appendError(_ text: String) { lock.withLock { errors += text } }
    func readErrors() -> String { lock.withLock { errors } }
}

private struct OneShotConsent: ExternalDataConsentStoring {
    func status() async -> ExternalDataConsentStatus { .current(.init(schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion, policyVersion: ExternalDataConsentReceipt.currentPolicyVersion, acceptedAt: Date(), externalProviderRiskAccepted: true, documentToolAccessAccepted: true)) }
    func acceptBothStatements(at date: Date) async throws {}
    func revoke() async throws {}
}
private struct OneShotSelection: LocalIntelligenceSelectionStoring {
    let stateValue: LocalIntelligenceSelectionState
    func state() async -> LocalIntelligenceSelectionState { stateValue }
    func selectApple(at date: Date) async throws {}
    func selectExternal(_ identity: LocalModelIdentity, qualification: LocalModelQualificationReceipt, acknowledgment: ExternalLocalModelAcknowledgment) async throws {}
    func reset(at date: Date) async throws {}
}
private actor OneShotTransport: ModelBridgeTransporting {
    var calls = 0
    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse {
        calls += 1
        throw IntelligenceError.generationFailed
    }
}

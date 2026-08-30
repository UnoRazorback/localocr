import Foundation
@testable import LocalOCRModelBridgeKit
import LocalOCRModelBridgeProtocol
import Testing

@Suite("Model bridge server")
struct ModelBridgeServerTests {
    @Test
    func productionCompositionRoutesFramedOllamaDiscovery() async throws {
        let http = CompositionFixtureHTTP(responses: [
            Data(#"{"version":"0.11.7"}"#.utf8),
            Data(
                #"{"models":[{"name":"gemma4:8b","model":"gemma4:8b","size":5234567890,"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","details":{"format":"gguf"}}]}"#.utf8
            )
        ])
        let server = ModelBridgeServer(
            handler: ModelBridgeProductionComposition.handler(http: http)
        )
        var frame = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 501, provider: .ollama)
        )
        frame.append(10)

        let response = await server.consume(frame)

        #expect(response.id == 501)
        #expect(response.candidates.map(\.identity.model) == ["gemma4:8b"])
        #expect(response.candidates.first?.locality == .verifiedLocal)
        #expect(response.error == nil)
        #expect(await http.endpoints == [.ollamaVersion, .ollamaTags])
    }

    @Test
    func productionCompositionRoutesLMStudioDiscovery() async {
        let http = CompositionFixtureHTTP(responses: [
            Data(
                #"{"models":[{"type":"llm","publisher":"lmstudio-community","key":"lmstudio-community/gemma-3-4b-it-GGUF","display_name":"Gemma 3 4B IT","architecture":"gemma3","quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":4294967296,"params_string":"4B","loaded_instances":[{"id":"gemma-instance","config":{"context_length":4096}}],"max_context_length":131072,"format":"gguf","capabilities":{"vision":false,"trained_for_tool_use":false},"description":null,"variants":["lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"],"selected_variant":"lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"}]}"#.utf8
            )
        ])
        let handler = ModelBridgeProductionComposition.handler(
            http: http,
            lmStudioCLI: CompositionFixtureLMStudioCLI()
        )

        let response = await handler.handle(.discover(id: 502, provider: .lmStudio))

        #expect(response.id == 502)
        #expect(response.candidates.map(\.identity.model) == ["lmstudio-community/gemma-3-4b-it-GGUF"])
        #expect(response.candidates.first?.locality == .verifiedLocal)
        #expect(response.error == nil)
        #expect(await http.endpoints == [.lmStudioModels])
    }

    @Test func providerDiscoveryPreservesStableSourceFailureCategories() async {
        let fixtures: [([CompositionFixtureHTTP.Outcome], ModelBridgeWireErrorCode)] = [
            ([.error(.timedOut)], .generationTimedOut),
            ([.error(.responseTooLarge)], .providerResponseInvalid),
            ([.error(.redirectRejected)], .localityBlocked),
            ([.error(.authenticationRejected)], .localityBlocked),
            ([.error(.nonLoopbackResponse)], .localityBlocked),
            ([.error(.cancelled)], .cancelled),
            ([.error(.invalidStatus(500))], .providerUnavailable),
            ([.cancelled], .cancelled),
            ([.data(Data(#"{"version":17}"#.utf8)), .data(Data(#"{"models":[]}"#.utf8))],
             .providerResponseInvalid)
        ]

        for (outcomes, expected) in fixtures {
            let handler = ModelBridgeProductionComposition.handler(
                http: CompositionFixtureHTTP(outcomes: outcomes)
            )
            let response = await handler.handle(.discover(id: 510, provider: .ollama))

            #expect(response.error?.code == expected)
            #expect(response.candidates.isEmpty)
        }
    }

    @Test func ollamaStatusClassifiesExactCandidateBeforeLocalityFiltering() async throws {
        let model = "gemma4:8b"
        let cases: [(Data, ModelBridgeWireErrorCode)] = [
            (Data(#"{"models":[]}"#.utf8), .modelUnavailable),
            (try ollamaStatusTags(model: model, size: 0), .localityUnverified),
            (try ollamaStatusTags(model: model, remoteHost: "https://example.invalid"), .localityBlocked),
            (try ollamaStatusTags(model: model, duplicate: true), .providerResponseInvalid)
        ]

        for (tags, expected) in cases {
            let handler = ModelBridgeProductionComposition.handler(
                http: CompositionFixtureHTTP(responses: [
                    Data(#"{"version":"0.11.8"}"#.utf8),
                    tags
                ])
            )

            let response = await handler.handle(.status(id: 511, provider: .ollama, model: model))

            #expect(response.error?.code == expected)
            #expect(response.identity == nil)
        }
    }

    @Test func lmStudioStatusClassifiesExactCandidateBeforeLocalityFiltering() async throws {
        let model = "lmstudio-community/gemma-3-4b-it-GGUF"
        let missing = Data(#"{"models":[]}"#.utf8)
        let valid = try lmStudioStatusModels(model: model)
        let duplicate = try lmStudioStatusModels(model: model, duplicate: true)
        let cases: [(Data, CompositionFixtureLMStudioCLI, ModelBridgeWireErrorCode)] = [
            (missing, .init(), .modelUnavailable),
            (valid, .init(models: []), .localityUnverified),
            (valid, .init(link: .init(enabled: true, connectedPeerCount: 1)), .localityBlocked),
            (duplicate, .init(), .providerResponseInvalid)
        ]

        for (models, cli, expected) in cases {
            let handler = ModelBridgeProductionComposition.handler(
                http: CompositionFixtureHTTP(responses: [models]),
                lmStudioCLI: cli
            )

            let response = await handler.handle(.status(id: 512, provider: .lmStudio, model: model))

            #expect(response.error?.code == expected)
            #expect(response.identity == nil)
        }
    }

    @Test
    func productionCompositionExitsCleanlyOnEOFWithoutHTTP() async throws {
        let http = CompositionFixtureHTTP(responses: [])
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(
            handler: ModelBridgeProductionComposition.handler(http: http)
        )
        try input.fileHandleForWriting.close()

        await server.run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        #expect((try output.fileHandleForReading.readToEnd()) ?? Data() == Data())
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
        #expect(await http.endpoints.isEmpty)
    }

    @Test
    func builtExecutableUsesProductionCompositionForOllamaRequest() throws {
        let executableURL = try builtModelBridgeExecutableURL()
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics

        try process.run()
        var request = try JSONEncoder().encode(
            ModelBridgeRequest.status(id: 503, provider: .ollama)
        )
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = try #require(try output.fileHandleForReading.readToEnd())
        let lines = outputData.split(separator: 10)
        let response = try JSONDecoder().decode(
            ModelBridgeResponse.self,
            from: Data(try #require(lines.first))
        )
        #expect(process.terminationStatus == 0)
        #expect(lines.count == 1)
        #expect(response.id == 503)
        #expect(response.error?.code == .invalidRequest)
        #expect(response.error?.message == "Ollama status requires an exact model identifier.")
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }

    @Test
    func serverRejectsMessagesOverOneMiBBeforeDispatch() async {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)

        let result = await server.consume(
            Data(repeating: 65, count: 1_048_577) + Data([10])
        )

        #expect(result.error?.code == .messageTooLarge)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func serverDispatchesValidFrameAndCorrelatesHandlerResponse() async throws {
        let handler = WrongIDBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        var frame = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 42, provider: .ollama)
        )
        frame.append(10)

        let result = await server.consume(frame)

        #expect(result.id == 42)
        #expect(result.error == nil)
    }

    @Test
    func serverReturnsUnsupportedVersionWithParsedRequestID() async throws {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        let frame = try framedJSON([
            "version": 2,
            "id": 73,
            "action": "discover",
            "provider": "ollama",
            "fields": [],
            "timeoutMilliseconds": 10_000
        ])

        let result = await server.consume(frame)

        #expect(result.id == 73)
        #expect(result.error?.code == .unsupportedVersion)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func serverReturnsInvalidRequestWithParsedRequestID() async throws {
        let handler = RecordingBridgeHandler()
        let server = ModelBridgeServer(handler: handler)
        let frame = try framedJSON([
            "version": 1,
            "id": 91,
            "action": "discover",
            "provider": "ollama",
            "fields": [],
            "timeoutMilliseconds": 10_000,
            "document": "forbidden"
        ])

        let result = await server.consume(frame)

        #expect(result.id == 91)
        #expect(result.error?.code == .invalidRequest)
        #expect(await handler.requestCount == 0)
    }

    @Test
    func unimplementedHandlerReturnsStableProviderError() async {
        let response = await UnimplementedModelBridgeHandler().handle(
            .discover(id: 5, provider: .lmStudio)
        )

        #expect(response.id == 5)
        #expect(response.error?.code == .providerNotImplemented)
        #expect(response.error?.message == "Provider adapter is not implemented.")
    }

    @Test
    func runWritesOneJSONResponsePerRequestAndNoDiagnostics() async throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())
        let first = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 11, provider: .ollama)
        )
        let second = try JSONEncoder().encode(
            ModelBridgeRequest.discover(id: 12, provider: .lmStudio)
        )
        try input.fileHandleForWriting.write(contentsOf: first + Data([10]) + second + Data([10]))
        try input.fileHandleForWriting.close()

        await server.run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        let outputData = try #require(try output.fileHandleForReading.readToEnd())
        let lines = outputData.split(separator: 10)
        let responses = try lines.map {
            try JSONDecoder().decode(ModelBridgeResponse.self, from: Data($0))
        }
        #expect(responses.map(\.id) == [11, 12])
        #expect(responses.allSatisfy { $0.error?.code == .providerNotImplemented })
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }

    @Test
    func runExitsCleanlyOnImmediateEOF() async throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())
        try input.fileHandleForWriting.close()

        await server.run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        #expect((try output.fileHandleForReading.readToEnd()) ?? Data() == Data())
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }

    @Test
    func runReadsOversizedRegularFileInBoundedChunksAndWritesOneError() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-bridge-oversized-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        try (Data(repeating: 65, count: 4 * 1_048_576) + Data([10])).write(
            to: fixtureURL,
            options: .atomic
        )
        let baseHandle = try FileHandle(forReadingFrom: fixtureURL)
        defer { try? baseHandle.close() }
        let input = RecordingBoundedFileInput(handle: baseHandle)
        let output = Pipe()
        let diagnostics = Pipe()
        let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())

        await server.run(
            input: input,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()

        let outputData = try #require(try output.fileHandleForReading.readToEnd())
        let lines = outputData.split(separator: 10)
        let response = try JSONDecoder().decode(
            ModelBridgeResponse.self,
            from: Data(try #require(lines.first))
        )
        #expect(lines.count == 1)
        #expect(response.id == 0)
        #expect(response.error?.code == .messageTooLarge)
        #expect(response.error?.message == "Request exceeds the one-MiB limit.")
        #expect(input.requestedReadCounts.count > 1)
        #expect(input.requestedReadCounts.allSatisfy { $0 <= 65_536 })
        #expect((try diagnostics.fileHandleForReading.readToEnd()) ?? Data() == Data())
    }
}

private actor CompositionFixtureHTTP: LoopbackHTTPPerforming {
    enum Outcome: Sendable {
        case data(Data)
        case error(LoopbackHTTPError)
        case cancelled
    }

    private var outcomes: [Outcome]
    private(set) var endpoints: [ApprovedLoopbackEndpoint] = []

    init(responses: [Data]) {
        outcomes = responses.map(Outcome.data)
    }

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func perform(
        _ endpoint: ApprovedLoopbackEndpoint,
        body: Data?,
        timeoutMilliseconds: Int
    ) async throws -> Data {
        endpoints.append(endpoint)
        switch outcomes.removeFirst() {
        case let .data(data):
            return data
        case let .error(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

private struct CompositionFixtureLMStudioCLI: LMStudioCLIProbing {
    let link: LMStudioLinkStatus
    let models: [LMStudioLocalModel]
    let fixtureVersion: String

    init(
        link: LMStudioLinkStatus = .init(enabled: false, connectedPeerCount: 0),
        models: [LMStudioLocalModel]? = nil,
        version: String = "fixture-commit"
    ) {
        self.link = link
        self.models = models ?? [Self.fixtureModel]
        fixtureVersion = version
    }

    func linkStatus() async throws -> LMStudioLinkStatus {
        link
    }

    func localModels() async throws -> [LMStudioLocalModel] {
        models
    }

    func version() async throws -> String {
        fixtureVersion
    }

    private static let fixtureModel = LMStudioLocalModel(
        key: "lmstudio-community/gemma-3-4b-it-GGUF",
        selectedVariant: "lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m",
        variants: ["lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"],
        architecture: "gemma3",
        format: "gguf",
        quantization: "Q4_K_M",
        sizeBytes: 4_294_967_296
    )
}

private func ollamaStatusTags(
    model: String,
    size: Int = 5_234_567_890,
    remoteHost: String? = nil,
    duplicate: Bool = false
) throws -> Data {
    var item: [String: Any] = [
        "name": model,
        "model": model,
        "size": size,
        "digest": String(repeating: "a", count: 64),
        "details": ["format": "gguf"]
    ]
    if let remoteHost { item["remote_host"] = remoteHost }
    let models = duplicate ? [item, item] : [item]
    return try JSONSerialization.data(withJSONObject: ["models": models])
}

private func lmStudioStatusModels(model: String, duplicate: Bool = false) throws -> Data {
    let item: [String: Any] = [
        "type": "llm",
        "publisher": "lmstudio-community",
        "key": model,
        "display_name": "Gemma 3 4B IT",
        "architecture": "gemma3",
        "quantization": ["name": "Q4_K_M", "bits_per_weight": 4],
        "size_bytes": 4_294_967_296,
        "params_string": "4B",
        "loaded_instances": [["id": "gemma-instance", "config": ["context_length": 4096]]],
        "max_context_length": 131_072,
        "format": "gguf",
        "capabilities": ["vision": false, "trained_for_tool_use": false],
        "description": NSNull(),
        "variants": ["\(model)@q4_k_m"],
        "selected_variant": "\(model)@q4_k_m"
    ]
    let models = duplicate ? [item, item] : [item]
    return try JSONSerialization.data(withJSONObject: ["models": models])
}

private func builtModelBridgeExecutableURL() throws -> URL {
    var directories = [
        Bundle.main.bundleURL.deletingLastPathComponent(),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug")
    ]
    var argumentDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<10 {
        directories.append(argumentDirectory)
        argumentDirectory.deleteLastPathComponent()
    }
    for directory in directories {
        let candidate = directory.appendingPathComponent("localocr-model-bridge")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

private actor RecordingBridgeHandler: ModelBridgeHandling {
    private(set) var requestCount = 0

    func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse {
        requestCount += 1
        return ModelBridgeResponse(id: request.id)
    }
}

private actor WrongIDBridgeHandler: ModelBridgeHandling {
    func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse {
        ModelBridgeResponse(id: 999)
    }
}

private func framedJSON(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
}

private final class RecordingBoundedFileInput: ModelBridgeInputReading, @unchecked Sendable {
    private let lock = NSLock()
    private var readCounts: [Int] = []
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    var requestedReadCounts: [Int] {
        lock.withLock { readCounts }
    }

    func read(upToCount count: Int) throws -> Data? {
        lock.withLock { readCounts.append(count) }
        return try handle.read(upToCount: count)
    }
}

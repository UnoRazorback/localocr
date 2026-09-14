import Darwin
import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import LocalOCRService
import Testing

@Suite struct Build8EnduranceAcceptanceTests {
    // Catches dropped/duplicated lifecycle writes, identity drift, lost receipts after idle,
    // or flat OCR that prevents grounding the equipment amount to its row on page 1.
    @Test func twentySequentialGenerationsRetainQualificationAndContentFreeEndedRecordsAfterTenMinutes() async throws {
        let root = try task6PhysicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("build8-endurance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Build8ManualClock()
        let identity = LocalModelIdentity(
            provider: .llamaCpp, model: "synthetic-endurance", fingerprint: String(repeating: "a", count: 64),
            harnessVersion: "version: 1 (a2878d30d)", fileAttestation: LocalModelFileAttestation(
                executablePath: "/synthetic/llama-server", executableSHA256: String(repeating: "b", count: 64),
                modelPath: "/synthetic/fixture.gguf", modelSize: 100, modelModifiedNanoseconds: 1,
                executableSize: 200, executableModifiedNanoseconds: 2, processID: 123))
        let transport = Task6Transport { request in
            if request.action == .discover {
                #expect(request.provider == .llamaCpp)
                return task6DiscoveryResponse(request: request, candidates: [task6Candidate(identity: identity)])
            }
            #expect(request.expectedIdentity == identity)
            let payload = request.fields == ["equipment"]
                ? #"{"fields":[{"name":"equipment","value":"$2,000.00","page":1,"evidence":"Equipment | Lift and delivery | $2,000.00"}]}"#
                : task6GeneratedPayload(for: try #require(request.operation))
            return ModelBridgeResponse(id: request.id, payloadJSON: payload, identity: identity)
        }
        let factory: LocalModelQualificationService.ProviderFactory = { identity in
            BridgeBackedIntelligenceProvider(identity: identity, qualifiedAt: clock.now(), transport: transport)
        }
        let cache = root.appendingPathComponent("qualification")
        let qualification = LocalModelQualificationService(providerFactory: factory, now: { clock.now() }, cacheDirectory: cache)
        let outcome = try await qualification.qualify(identity)
        #expect(outcome.status == .passed)
        let receipt = try #require(outcome.receipt)
        let selectionURL = root.appendingPathComponent("selection/receipt.json")
        let selection = LocalIntelligenceSelectionStore(receiptURL: selectionURL)
        let acknowledgment = task6Acknowledgment(identity: identity)
        try await selection.selectExternal(identity, qualification: receipt, acknowledgment: acknowledgment)
        let ledger = LocalAIActivityLedger(containerURL: root, clock: clock)
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: clock)
        let router = LocalIntelligenceProviderRouter(selectionStore: selection, transport: transport,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            activityReporter: reporter)

        let table = OCRLayoutTextAssembler.text(for: [
            OCRLineResponse(text: "$2,000.00", confidence: 0.99, x: 0.72, y: 0.64, width: 0.16, height: 0.08),
            OCRLineResponse(text: "Lift and delivery", confidence: 0.99, x: 0.29, y: 0.65, width: 0.31, height: 0.08),
            OCRLineResponse(text: "Equipment", confidence: 0.99, x: 0.05, y: 0.63, width: 0.16, height: 0.10),
        ], fallback: "Equipment\nLift and delivery\n$2,000.00")
        let equipment = IntelligenceDocument(pages: [.init(number: 1, text: table)])
        let active = root.appendingPathComponent("LocalAIActivity/v1/active")
        let recent = root.appendingPathComponent("LocalAIActivity/v1/recent")
        let initialGenerationCount = await transport.requests.filter { $0.action == .generate }.count
        for index in 0..<20 {
            let result = try await router.extract(["equipment"], from: equipment)
            #expect(result.value == [.init(name: "equipment", value: "$2,000.00", sourcePage: 1,
                evidence: "Equipment | Lift and delivery | $2,000.00")])
            #expect(result.model.fingerprint == identity.fingerprint)
            #expect(try FileManager.default.contentsOfDirectory(atPath: active.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: recent.path).count == index + 1)
        }
        #expect(await transport.requests.filter { $0.action == .generate }.count - initialGenerationCount == 20)
        #expect(clock.pendingSleepCount == 0)
        clock.advance(seconds: 600)
        #expect(clock.elapsedSeconds == 600)
        let reloaded = LocalIntelligenceSelectionStore(receiptURL: selectionURL)
        #expect(await reloaded.state() == .selected(.external(identity: identity, qualification: receipt, acknowledgment: acknowledgment)))
        #expect(await router.availability == .available)
        let reloadedQualification = LocalModelQualificationService(providerFactory: factory, now: { clock.now() }, cacheDirectory: cache)
        #expect(await reloadedQualification.cachedOutcome(for: identity)?.receipt == receipt)
        #expect(await reloadedQualification.cachedOutcome(for: identity)?.status == .passed)
        await ledger.cleanupExpired()
        let activeFiles = try FileManager.default.contentsOfDirectory(atPath: active.path)
        let files = try FileManager.default.contentsOfDirectory(at: recent, includingPropertiesForKeys: nil)
        #expect(activeFiles.isEmpty)
        #expect(files.count == 20)
        var ids = Set<String>()
        for file in files {
            let data = try Data(contentsOf: file)
            let record = try LocalAIActivityContract.decode(data)
            #expect(record.productTask == .extract)
            #expect(record.route == .onDeviceLoopback)
            #expect(record.producerRole == .studio)
            #expect(record.endedAt == task6Now)
            #expect(clock.now().timeIntervalSince(try #require(record.endedAt)) == 600)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.count == 17)
            #expect(Set(json.keys) == LocalAIActivityContract.v1Keys)
            #expect(json["state"] as? String == "ended")
            #expect(json["outcome"] as? String == "success")
            #expect(json["runtime_identifier"] is NSNull)
            #expect(json["runtime_family"] as? String == "local_runtime")
            #expect(json["ended_at"] as? String != nil)
            let id = try #require(json["activity_id"] as? String)
            #expect(UUID(uuidString: id) != nil)
            #expect(file.deletingPathExtension().lastPathComponent.lowercased() == id.lowercased())
            #expect(ids.insert(id).inserted)
            let text = String(decoding: data, as: UTF8.self)
            for forbidden in ["$2,000.00", "Q-104", "Equipment", identity.model, identity.fingerprint!, root.path, "/synthetic/"] {
                #expect(!text.contains(forbidden))
            }
        }
        #expect(ids.count == 20)
    }
}

// A forward-only elapsed counter drives the injected wall-clock projection. Heartbeat
// sleepers suspend until cancellation; all twenty operations finish before idle advances.
private final class Build8ManualClock: LocalAIActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = 0
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var elapsedSeconds: Int { lock.withLock { elapsed } }
    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
    func now() -> Date { task6Now.addingTimeInterval(TimeInterval(elapsedSeconds)) }
    func advance(seconds: Int) {
        precondition(seconds >= 0)
        lock.withLock { elapsed += seconds }
    }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

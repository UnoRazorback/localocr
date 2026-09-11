import Foundation
import Testing
@testable import LocalOCRModelBridgeKit

struct LlamaCppLiveDiagnosticTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALOCR_LIVE_LLAMA_TEST"] == "1"))
    func realProcessAttestation() async throws {
        let result = try await LlamaCppProcessProbe().snapshot()
        #expect(!result.alias.isEmpty)
        print("LIVE HARNESS: \(result.harnessVersion)")
    }
}

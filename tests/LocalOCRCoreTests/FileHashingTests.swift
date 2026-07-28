import Foundation
import LocalOCRCore
import Testing

@Test func hashesWithoutLoadingWholeFile() async throws {
    let url = try FixtureFiles.write(bytes: Array(repeating: 0x61, count: 2_000_000))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try await FileHashing.sha256(of: url) ==
        "bcf7f9d1b4311c3352e60502255ce09a6744df84e8f2c89f79c4b5d74933a95a")
}

private enum FixtureFiles {
    static func write(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data(bytes).write(to: url)
        return url
    }
}

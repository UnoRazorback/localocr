import CoreGraphics
import Foundation
import ImageIO
@testable import LocalOCRCore
import Testing

@Suite(.serialized) struct OCRCacheTests {
    @Test func persistsValueAcrossCacheInstances() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let key = makeKey()
        let expected = makeCandidate(text: "persisted")

        let writer = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        try await writer.store(expected, for: key)

        let reader = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        #expect(try await reader.value(for: key) == expected)
    }

    @Test func keepsEntriesDistinctForRecognitionSettings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        let defaultSettings = RecognitionSettings(dpi: 250, forceOCR: false, recognitionLanguages: ["en-US"])
        let differentDPI = RecognitionSettings(dpi: 300, forceOCR: false, recognitionLanguages: ["en-US"])
        let differentLanguage = RecognitionSettings(dpi: 250, forceOCR: false, recognitionLanguages: ["fr-FR"])
        let forced = RecognitionSettings(dpi: 250, forceOCR: true, recognitionLanguages: ["en-US"])
        let keys = [defaultSettings, differentDPI, differentLanguage, forced].map {
            OCRCacheKey(sourceSHA256: "source", page: 7, settings: $0, compatibilityVersion: "v1")
        }
        let values = ["default", "dpi", "language", "forced"].map(makeCandidate(text:))

        for (key, value) in zip(keys, values) {
            try await cache.store(value, for: key)
        }

        for (key, expected) in zip(keys, values) {
            #expect(try await cache.value(for: key) == expected)
        }
    }

    @Test func treatsCorruptEntryAsMissAndRemovesIt() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        let key = makeKey()
        try await cache.store(makeCandidate(text: "valid"), for: key)
        let cacheFile = try #require(cacheFiles(in: rootURL).first)
        try Data("not JSON".utf8).write(to: cacheFile)

        #expect(try await cache.value(for: key) == nil)
        #expect(cacheFiles(in: rootURL).isEmpty)
    }

    @Test func concurrentWritesToSameKeyLeaveAReadableCandidate() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let key = makeKey()
        let candidates = (0 ..< 32).map { makeCandidate(text: "value-\($0)") }
        let writers = candidates.map { _ in OCRCache(rootURL: rootURL, compatibilityVersion: "v1") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (candidate, writer) in zip(candidates, writers) {
                group.addTask {
                    try await writer.store(candidate, for: key)
                }
            }
            try await group.waitForAll()
        }

        let reader = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        let stored = try #require(try await reader.value(for: key))
        #expect(candidates.contains(stored))
    }

    @Test func removeAllDeletesStoredEntries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cache = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")
        let first = makeKey(page: 1)
        let second = makeKey(page: 2)
        try await cache.store(makeCandidate(text: "first"), for: first)
        try await cache.store(makeCandidate(text: "second"), for: second)

        try await cache.removeAll()

        #expect(try await cache.value(for: first) == nil)
        #expect(try await cache.value(for: second) == nil)
        #expect(cacheFiles(in: rootURL).isEmpty)
    }

    @Test func restrictsCacheDirectoriesToTheCurrentUser() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootURL.path)
        let cache = OCRCache(rootURL: rootURL, compatibilityVersion: "v1")

        try await cache.store(makeCandidate(text: "private"), for: makeKey())

        let cacheFile = try #require(cacheFiles(in: rootURL).first)
        #expect(permissions(of: rootURL) == 0o700)
        #expect(permissions(of: cacheFile.deletingLastPathComponent()) == 0o700)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OCRCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeKey(page: Int = 1) -> OCRCacheKey {
    OCRCacheKey(
        sourceSHA256: "0123456789abcdef",
        page: page,
        settings: RecognitionSettings(dpi: 250, recognitionLanguages: ["en-US"]),
        compatibilityVersion: "v1"
    )
}

private func makeCandidate(text: String) -> RecognitionCandidate {
    RecognitionCandidate(
        orientation: .up,
        lines: [TextLine(text: text, confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))]
    )
}

private func cacheFiles(in rootURL: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ))?.flatMap { shardURL in
        (try? FileManager.default.contentsOfDirectory(
            at: shardURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }.filter { $0.pathExtension == "json" } ?? []
}

private func permissions(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

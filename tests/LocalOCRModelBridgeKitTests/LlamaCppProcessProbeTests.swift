import Foundation
import CryptoKit
import Testing
@testable import LocalOCRModelBridgeKit

struct LlamaCppProcessProbeTests {
    let good = ["llama-server", "--model", "/local/test.gguf", "--alias", "test", "--host", "127.0.0.1", "--port", "8080", "--no-webui", "--jinja", "--reasoning", "off"]
    @Test func explicitLocalArguments() throws {
        #expect(try LlamaCppProcessProbe.parseArguments(good).alias == "test")
        #expect(try LlamaCppProcessProbe.parseArguments(good.map { $0 == "127.0.0.1" ? "::1" : $0 }).host == "::1")
    }
    @Test func rejectRemoteOrAmbiguousArguments() {
        for host in ["localhost", "0.0.0.0", "::", "example.com", "192.168.1.1"] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.parseArguments(good.map { $0 == "127.0.0.1" ? host : $0 }) }
        }
        for extras in [["--rpc", "127.0.0.1:9000"], ["--model", "/second.gguf"], ["--host", "::1"], ["--model-url", "https://example.com/a.gguf"], ["--hf-repo", "x/y"], ["--ssh", "host"], ["--lora", "/local/a.gguf"], ["--models-dir", "/models"]] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.parseArguments(good + extras) }
        }
        for env in ["LLAMA_ARG_RPC=server:9", "LLAMA_ARG_HOST=0.0.0.0", "DYLD_INSERT_LIBRARIES=/x"] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.parseArguments(good, environment: [env]) }
        }
    }
    @Test func listenersMustBeUniqueAndLoopback() throws {
        #expect(try LlamaCppProcessProbe.listenerPID(Data("p42\nn127.0.0.1:8080\n".utf8)) == 42)
        #expect(try LlamaCppProcessProbe.listenerPID(Data("p42\nn[::1]:8080\n".utf8)) == 42)
        for invalid in ["", "p1\nn*:8080\n", "p1\nnlocalhost:8080\n", "p1\nn127.0.0.1:8080\np2\nn[::1]:8080\n"] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.listenerPID(Data(invalid.utf8)) }
        }
    }
    @Test func versionIsBoundedAndSpecific() throws {
        #expect(try LlamaCppProcessProbe.validVersion(Data("version: 10909 (a2878d30d)\nbuilt with clang\n".utf8)) == "version: 10909 (a2878d30d)")
        for bad in ["hello", "version: arbitrary", String(repeating: "x", count: 17000)] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.validVersion(Data(bad.utf8)) }
        }
    }
    @Test func localFileIdentityAndSymlinkReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.gguf"), b = dir.appendingPathComponent("b.gguf"), link = dir.appendingPathComponent("selected.gguf")
        try Data("model a".utf8).write(to: a); try Data("model b".utf8).write(to: b)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let pinned = try PinnedLocalFile(link.path, executable: false)
        try pinned.revalidate()
        try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(throws: (any Error).self) { try pinned.revalidate() }
        let original = try PinnedLocalFile(a.path, executable: false)
        try Data("changed model contents".utf8).write(to: a)
        #expect(throws: (any Error).self) { try original.revalidate() }
        #expect(throws: (any Error).self) { try PinnedLocalFile(dir.path, executable: false) }
    }
    @Test func concurrentColdHashesPublishOneCompleteCacheEntryAndWarmReuseDoesNotRewriteIt() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("fixture.gguf")
        let cache = root.appendingPathComponent("cache")
        try Data("abc".utf8).write(to: model)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let hashes = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let pinned = try PinnedLocalFile(model.path, executable: false)
                    return try await LlamaCppProcessProbe(cacheDirectory: cache).cachedHash(pinned)
                }
            }
            var result: [String] = []
            for try await hash in group { result.append(hash) }
            return result
        }
        #expect(hashes.count == 12)
        #expect(hashes.allSatisfy { $0 == expected })
        let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.pathExtension == "sha256")
        let keyEncoder = JSONEncoder()
        keyEncoder.outputFormatting = [.sortedKeys]
        let identity = try PinnedLocalFile(model.path, executable: false).identity
        let key = SHA256.hash(data: try keyEncoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        #expect(entry.lastPathComponent == key + ".sha256")
        #expect(try String(contentsOf: entry, encoding: .utf8) == expected)
        // A crashed publication leaves only an unrelated pending filename.
        try Data().write(to: cache.appendingPathComponent(".pending-crashed-writer"))
        let before = try FileManager.default.attributesOfItem(atPath: entry.path)
        let pinned = try PinnedLocalFile(model.path, executable: false)
        #expect(try await LlamaCppProcessProbe(cacheDirectory: cache).cachedHash(pinned) == expected)
        let after = try FileManager.default.attributesOfItem(atPath: entry.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test func digestCacheRejectsSymlinkEntryWithoutChangingItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("fixture.gguf")
        let cache = root.appendingPathComponent("cache")
        try Data("abc".utf8).write(to: model)
        let pinned = try PinnedLocalFile(model.path, executable: false)
        let probe = LlamaCppProcessProbe(cacheDirectory: cache)
        let hash = try await probe.cachedHash(pinned)
        let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        let entry = try #require(entries.first)
        let target = root.appendingPathComponent("target")
        try Data(hash.utf8).write(to: target)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await probe.cachedHash(pinned) }
        #expect(try String(contentsOf: target, encoding: .utf8) == hash)
    }

}

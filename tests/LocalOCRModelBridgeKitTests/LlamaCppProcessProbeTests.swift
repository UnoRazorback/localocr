import Foundation
import CryptoKit
import Darwin
import Testing
@testable import LocalOCRModelBridgeKit

struct LlamaCppProcessProbeTests {
    @Test func twentyIndependentProbesReuseAttestedVersionAndChangedIdentityMisses() async throws {
        let fixture = try VersionCacheFixture()
        defer { fixture.remove() }
        let loader = VersionLoaderCounter()
        for _ in 0..<20 {
            let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
            let version = try await LlamaCppProcessProbe(cacheDirectory: fixture.cache,
                versionLoader: { fd, path in try await loader.load(fd, path) }).cachedVersion(pinned)
            #expect(version == "version: 10909 (a2878d30d)")
        }
        #expect(await loader.calls == 1)
        let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
        let entry = try fixture.entry(pinned)
        let before = try FileManager.default.attributesOfItem(atPath: entry.path)
        _ = try await LlamaCppProcessProbe(cacheDirectory: fixture.cache,
            versionLoader: { fd, path in try await loader.load(fd, path) }).cachedVersion(pinned)
        let after = try FileManager.default.attributesOfItem(atPath: entry.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        try fixture.replaceExecutable()
        let changed = try PinnedLocalFile(fixture.executable.path, executable: true)
        #expect(try await LlamaCppProcessProbe(cacheDirectory: fixture.cache,
            versionLoader: { fd, path in try await loader.load(fd, path) }).cachedVersion(changed) == "version: 10909 (a2878d30d)")
        #expect(await loader.calls == 2)
    }

    @Test func invalidLoaderResultAndMidLoadExecutableReplacementNeverPublish() async throws {
        for kind in ["malformed", "oversized", "identity", "cancelled", "timedOut"] {
            let fixture = try VersionCacheFixture()
            defer { fixture.remove() }
            let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
            let probe = LlamaCppProcessProbe(cacheDirectory: fixture.cache, versionLoader: { _, _ in
                if kind == "identity" { try fixture.replaceExecutable() }
                if kind == "cancelled" { throw LMStudioCLIProbeError.cancelled }
                if kind == "timedOut" { throw LMStudioCLIProbeError.timedOut }
                if kind == "malformed" { return Data("version: garbage".utf8) }
                if kind == "oversized" { return Data(("version: " + String(repeating: "1", count: 500) + " (abcdef0)").utf8) }
                return Data("version: 10909 (a2878d30d)".utf8)
            })
            await #expect(throws: (any Error).self) { try await probe.cachedVersion(pinned) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
        }
    }

    @Test func unsafeTargetAppearingDuringLoadIsNotOverwritten() async throws {
        let fixture = try VersionCacheFixture()
        defer { fixture.remove() }
        let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
        let entry = try fixture.entry(pinned)
        let target = fixture.root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        let probe = LlamaCppProcessProbe(cacheDirectory: fixture.cache, versionLoader: { _, _ in
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
            return Data("version: 10909 (a2878d30d)".utf8)
        })
        await #expect(throws: (any Error).self) { try await probe.cachedVersion(pinned) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: entry.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count == 1)
    }

    @Test func anotherHelperWinningPublicationIsValidatedAndNeverRewritten() async throws {
        let fixture = try VersionCacheFixture()
        defer { fixture.remove() }
        let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
        let entry = try fixture.entry(pinned)
        let winner = VersionCacheWinner()
        let probe = LlamaCppProcessProbe(cacheDirectory: fixture.cache, versionLoader: { _, _ in
            // The outer helper has already observed ENOENT. Publish from a separate
            // helper before it returns, deterministically exercising the EEXIST path.
            let otherPinned = try PinnedLocalFile(fixture.executable.path, executable: true)
            _ = try await LlamaCppProcessProbe(cacheDirectory: fixture.cache, versionLoader: { _, _ in
                Data("version: 10909 (a2878d30d)".utf8)
            }).cachedVersion(otherPinned)
            try await winner.record(entry)
            return Data("version: 10909 (a2878d30d)".utf8)
        })
        #expect(try await probe.cachedVersion(pinned) == "version: 10909 (a2878d30d)")
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
        #expect(attributes[.systemFileNumber] as? NSNumber == (await winner.inode))
        #expect(attributes[.modificationDate] as? Date == (await winner.modified))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count == 1)
    }

    @Test func unsafeCacheDirectoryIsNotRepairedOrUsed() async throws {
        let fixture = try VersionCacheFixture()
        defer { fixture.remove() }
        #expect(chmod(fixture.cache.path, 0o755) == 0)
        let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
        let loader = VersionLoaderCounter()
        await #expect(throws: (any Error).self) {
            try await LlamaCppProcessProbe(cacheDirectory: fixture.cache,
                versionLoader: { fd, path in try await loader.load(fd, path) }).cachedVersion(pinned)
        }
        #expect(await loader.calls == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.cache.path)[.posixPermissions] as? NSNumber == 0o755)
    }

    @Test func cacheMetadataRejectsAnotherOwnerEvenWithOtherwiseSafeMetadata() {
        // An unprivileged test cannot chown a real file to another user. Exercise the
        // same stat validator used before and after reads, changing only the owner.
        var metadata = stat()
        metadata.st_mode = mode_t(S_IFREG | 0o600)
        metadata.st_uid = getuid()
        metadata.st_nlink = 1
        metadata.st_size = 24
        #expect(LlamaCppProcessProbe.versionCacheMetadataIsSafe(metadata))
        metadata.st_uid = getuid() == 0 ? 1 : 0
        #expect(!LlamaCppProcessProbe.versionCacheMetadataIsSafe(metadata))
    }

    @Test func unsafeVersionCacheEntriesFailClosedWithoutLoadingOrRewriting() async throws {
        for kind in ["empty", "oversized", "malformed", "symlink", "hardlink", "mode", "directory", "fifo"] {
            let fixture = try VersionCacheFixture()
            defer { fixture.remove() }
            let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
            let entry = try fixture.entry(pinned)
            let target = fixture.root.appendingPathComponent("target")
            let valid = Data("version: 10909 (a2878d30d)".utf8)
            try valid.write(to: target)
            #expect(chmod(target.path, 0o600) == 0)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
            case "hardlink": #expect(link(target.path, entry.path) == 0)
            case "directory": try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
            case "fifo": #expect(mkfifo(entry.path, 0o600) == 0)
            default:
                let oversized = Data(("version: " + String(repeating: "1", count: 494) + " (abcdef0)").utf8)
                let bytes = kind == "empty" ? Data() : kind == "oversized" ? oversized : kind == "malformed" ? Data("version: garbage".utf8) : valid
                try bytes.write(to: entry)
                #expect(chmod(entry.path, kind == "mode" ? 0o644 : 0o600) == 0)
            }
            let before = try FileManager.default.attributesOfItem(atPath: entry.path)
            let loader = VersionLoaderCounter()
            await #expect(throws: (any Error).self) {
                try await LlamaCppProcessProbe(cacheDirectory: fixture.cache,
                    versionLoader: { fd, path in try await loader.load(fd, path) }).cachedVersion(pinned)
            }
            #expect(await loader.calls == 0, "unsafe entry: \(kind)")
            let after = try FileManager.default.attributesOfItem(atPath: entry.path)
            #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
            #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
            #expect(try Data(contentsOf: target) == valid)
        }
    }

    @Test func changedPinnedExecutableCannotUseWarmVersion() async throws {
        let fixture = try VersionCacheFixture()
        defer { fixture.remove() }
        let pinned = try PinnedLocalFile(fixture.executable.path, executable: true)
        let loader = VersionLoaderCounter()
        let probe = LlamaCppProcessProbe(cacheDirectory: fixture.cache,
            versionLoader: { fd, path in try await loader.load(fd, path) })
        _ = try await probe.cachedVersion(pinned)
        try fixture.replaceExecutable()
        await #expect(throws: (any Error).self) { try await probe.cachedVersion(pinned) }
        #expect(await loader.calls == 1)
    }

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
        #expect(try LlamaCppProcessProbe.listenerPID(Data("p1101\nf3\nn127.0.0.1:8080\n".utf8)) == 1101)
        #expect(try LlamaCppProcessProbe.listenerPID(Data("p42\nn127.0.0.1:8080\n".utf8)) == 42)
        #expect(try LlamaCppProcessProbe.listenerPID(Data("p42\nn[::1]:8080\n".utf8)) == 42)
        for invalid in ["", "p1\nn*:8080\n", "p1\nnlocalhost:8080\n", "p1\nn127.0.0.1:8080\np2\nn[::1]:8080\n"] {
            #expect(throws: (any Error).self) { try LlamaCppProcessProbe.listenerPID(Data(invalid.utf8)) }
        }
    }
    @Test func versionIsBoundedAndSpecific() throws {
        #expect(try LlamaCppProcessProbe.validVersion(Data("version: 10909 (a2878d30d)\nbuilt with clang\n".utf8)) == "version: 10909 (a2878d30d)")
        #expect(try LlamaCppProcessProbe.validVersion(Data("version: 0.4.0-dev (build 10909, commit a2878d30d)\nbuilt with AppleClang\n".utf8)) == "version: 0.4.0-dev (build 10909, commit a2878d30d)")
        for bad in ["hello", "version: arbitrary", "version: 0.4.0-dev (build 10909, commit garbage)", String(repeating: "x", count: 17000)] {
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

private struct VersionCacheFixture {
    let root: URL
    var executable: URL { root.appendingPathComponent("llama-server") }
    var cache: URL { root.appendingPathComponent("cache") }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try replaceExecutable()
    }
    func replaceExecutable() throws {
        // Mach-O magic permits pinning; injected loader never executes this fixture.
        try (Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(UUID().uuidString.utf8)).write(to: executable, options: .atomic)
        guard chmod(executable.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    func entry(_ pinned: PinnedLocalFile) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(pinned.identity)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent(key + ".version")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor VersionLoaderCounter {
    var calls = 0
    func load(_ fd: Int32, _ path: String) throws -> Data {
        calls += 1
        var st = stat()
        #expect(fstat(fd, &st) == 0)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "llama-server")
        return Data("version: 10909 (a2878d30d)\nbuilt with clang\n".utf8)
    }
}

private actor VersionCacheWinner {
    var inode: NSNumber?
    var modified: Date?
    func record(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        inode = attributes[.systemFileNumber] as? NSNumber
        modified = attributes[.modificationDate] as? Date
    }
}

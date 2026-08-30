import Foundation
import Testing
@testable import LocalOCRStudioKit

@Suite struct AgentClientDiscoveryTests {
    @Test func findsExecutableClientsInBoundedApprovedLocations() throws {
        let fixture = try DiscoveryFixture()
        let codex = try fixture.executable(named: "codex")
        let claude = try fixture.executable(named: "claude")
        let candidates = [
            AgentClientDiscoveryCandidate(
                kind: .codex,
                executableURL: codex,
                approvedRootURL: fixture.root,
                displayName: "Codex",
                version: "1.2.3",
                minimumVersion: "1.0.0"
            ),
            AgentClientDiscoveryCandidate(
                kind: .claudeCode,
                executableURL: claude,
                approvedRootURL: fixture.root,
                displayName: "Claude Code",
                version: "2.1.207",
                minimumVersion: "2.0.0"
            ),
        ]

        let result = AgentClientDiscovery().discover(candidates: candidates)

        #expect(result.installations.map(\.kind) == [.codex, .claudeCode])
        #expect(result.rejections.isEmpty)
    }

    @Test func rejectsNonExecutableAndUnsupportedCandidates() throws {
        let fixture = try DiscoveryFixture()
        let plain = try fixture.file(named: "codex")
        let oldClaude = try fixture.executable(named: "claude")
        let candidates = [
            AgentClientDiscoveryCandidate(
                kind: .codex,
                executableURL: plain,
                approvedRootURL: fixture.root,
                displayName: "Codex"
            ),
            AgentClientDiscoveryCandidate(
                kind: .claudeCode,
                executableURL: oldClaude,
                approvedRootURL: fixture.root,
                displayName: "Claude Code",
                version: "1.9.9",
                minimumVersion: "2.0.0"
            ),
        ]

        let result = AgentClientDiscovery().discover(candidates: candidates)

        #expect(result.installations.isEmpty)
        #expect(result.rejections.map(\.reason) == [.notExecutable, .unsupportedVersion])
    }

    @Test func rejectsSymlinkWhoseResolvedTargetEscapesApprovedRoot() throws {
        let fixture = try DiscoveryFixture()
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outside = outsideRoot.appendingPathComponent("codex")
        try Data("fixture".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let link = fixture.root.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = AgentClientDiscovery().discover(candidates: [
            AgentClientDiscoveryCandidate(
                kind: .codex,
                executableURL: link,
                approvedRootURL: fixture.root,
                displayName: "Codex"
            ),
        ])

        #expect(result.installations.isEmpty)
        #expect(result.rejections.first?.reason == .escapedApprovedRoot)
    }
}

private struct DiscoveryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func executable(named name: String) throws -> URL {
        let url = try file(named: name)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

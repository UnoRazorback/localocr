import Foundation
import Darwin
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite("Model bridge client")
struct ModelBridgeClientTests {
    @Test
    func constructingClientDoesNotResolveOrLaunchHelper() {
        let locator = FailingIfCalledLocator()

        _ = StdioModelBridgeClient(executableLocator: locator)

        #expect(locator.callCount == 0)
    }

    @Test
    func locatorFindsStudioHelperOnlyUnderContentsHelpers() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let studioExecutable = fixture.root
            .appendingPathComponent("LocalOCR Studio.app/Contents/MacOS/LocalOCR Studio")
        let helper = fixture.root
            .appendingPathComponent("LocalOCR Studio.app/Contents/Helpers/localocr-model-bridge")
        try fixture.createExecutable(at: studioExecutable, contents: "")
        try fixture.createExecutable(at: helper, contents: "")
        let locator = RelativeModelBridgeExecutableLocator(currentExecutableURL: studioExecutable)

        #expect(try locator.executableURL() == helper)
    }

    @Test
    func locatorFindsHelperBesideCLIExecutable() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let cli = fixture.root.appendingPathComponent("bin/localocr")
        let helper = fixture.root.appendingPathComponent("bin/localocr-model-bridge")
        try fixture.createExecutable(at: cli, contents: "")
        try fixture.createExecutable(at: helper, contents: "")
        let locator = RelativeModelBridgeExecutableLocator(currentExecutableURL: cli)

        #expect(try locator.executableURL() == helper)
    }

    @Test
    func locatorRejectsUnrecognizedLaunchingExecutable() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let launcher = fixture.root.appendingPathComponent("bin/unrelated-app")
        let helper = fixture.root.appendingPathComponent("bin/localocr-model-bridge")
        try fixture.createExecutable(at: launcher, contents: "")
        try fixture.createExecutable(at: helper, contents: "")
        let locator = RelativeModelBridgeExecutableLocator(currentExecutableURL: launcher)

        #expect(throws: ModelBridgeExecutableLocatorError.unsupportedExecutableLayout) {
            try locator.executableURL()
        }
    }

    @Test
    func locatorRejectsHelperSymlinkEscapingAllowedDirectory() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let cli = fixture.root.appendingPathComponent("bin/localocr")
        let helper = fixture.root.appendingPathComponent("bin/localocr-model-bridge")
        try fixture.createExecutable(at: cli, contents: "")
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        let locator = RelativeModelBridgeExecutableLocator(currentExecutableURL: cli)

        #expect(throws: ModelBridgeExecutableLocatorError.unsafeHelperLocation) {
            try locator.executableURL()
        }
    }

    @Test
    func clientLaunchesAbsoluteFixtureAndDecodesCorrelatedResponse() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        try fixture.createExecutable(
            at: helper,
            contents: """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '{"version":1,"id":44,"candidates":[]}'
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        let response = try await client.send(.discover(id: 44, provider: .ollama))

        #expect(response.id == 44)
    }

    @Test
    func clientRejectsMismatchedResponseID() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        try fixture.createExecutable(
            at: helper,
            contents: """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '{"version":1,"id":45,"candidates":[]}'
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.responseIDMismatch(expected: 44, actual: 45)) {
            try await client.send(.discover(id: 44, provider: .ollama))
        }
    }

    @Test
    func clientRejectsMoreThanOneResponseLine() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        try fixture.createExecutable(
            at: helper,
            contents: """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '{"version":1,"id":44,"candidates":[]}'
            printf '%s\\n' '{"version":1,"id":44,"candidates":[]}'
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(.discover(id: 44, provider: .ollama))
        }
    }

    @Test
    func clientRejectsNonJSONPayloadResponse() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"payloadJSON":"not-json","identity":{"provider":"ollama","model":"gemma4:8b"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(fixtureGenerateRequest)
        }
    }

    @Test
    func clientRejectsSuccessFieldsCombinedWithError() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"payloadJSON":"{}","identity":{"provider":"ollama","model":"gemma4:8b"},"error":{"code":"generation_failed","message":"failed"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(fixtureGenerateRequest)
        }
    }

    @Test
    func clientRejectsDiscoveryResponseCarryingGenerationFields() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"payloadJSON":"{}","identity":{"provider":"ollama","model":"gemma4:8b"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(.discover(id: 44, provider: .ollama))
        }
    }

    @Test
    func clientRejectsStatusResponseCarryingGenerationPayload() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"payloadJSON":"{}","identity":{"provider":"ollama","model":"gemma4:8b"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(.status(id: 44, provider: .ollama, model: "gemma4:8b"))
        }
    }

    @Test
    func clientRejectsGenerateResponseCarryingDiscoveryCandidates() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[{"identity":{"provider":"ollama","model":"gemma4:8b"},"displayName":"Gemma 4 8B","locality":"verified_local","localityReason":"Verified local."}]}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(fixtureGenerateRequest)
        }
    }

    @Test
    func clientRejectsStatusSuccessWithoutIdentity() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[]}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(.status(id: 44, provider: .ollama, model: "gemma4:8b"))
        }
    }

    @Test
    func clientRejectsGenerateSuccessWithoutPayloadAndIdentity() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[]}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        await #expect(throws: ModelBridgeClientError.malformedResponse) {
            try await client.send(fixtureGenerateRequest)
        }
    }

    @Test
    func clientAcceptsStatusResponseCarryingOnlyIdentity() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"identity":{"provider":"ollama","model":"gemma4:8b"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        let response = try await client.send(
            .status(id: 44, provider: .ollama, model: "gemma4:8b")
        )

        #expect(response.identity?.model == "gemma4:8b")
        #expect(response.payloadJSON == nil)
    }

    @Test
    func clientAcceptsGenerateResponseCarryingPayloadAndIdentity() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = try fixture.createResponseHelper(
            """
            {"version":1,"id":44,"candidates":[],"payloadJSON":"{\\"summary\\":\\"ok\\"}","identity":{"provider":"ollama","model":"gemma4:8b"}}
            """
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))

        let response = try await client.send(fixtureGenerateRequest)

        #expect(response.payloadJSON == "{\"summary\":\"ok\"}")
        #expect(response.identity?.model == "gemma4:8b")
    }

    @Test
    func clientRejectsInvalidRequestBeforeResolvingHelper() async {
        let locator = FailingIfCalledLocator()
        let client = StdioModelBridgeClient(executableLocator: locator)
        let request = ModelBridgeRequest(
            version: 2,
            id: 44,
            action: .discover,
            provider: .ollama
        )

        await #expect(throws: ModelBridgeClientError.invalidRequest) {
            try await client.send(request)
        }
        #expect(locator.callCount == 0)
    }

    @Test
    func clientTimeoutForcesKillAndReapsTERMIgnoringHelper() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        let marker = fixture.root.appendingPathComponent("timeout-pid")
        try fixture.createExecutable(
            at: helper,
            contents: termIgnoringHelperScript(marker: marker, emitsOutput: false)
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))
        let request = ModelBridgeRequest.discover(
            id: 44,
            provider: .ollama,
            timeoutMilliseconds: 1_000
        )

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: ModelBridgeClientError.timedOut) {
            try await client.send(request)
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(!processExists(try helperPID(from: marker)))
    }

    @Test
    func clientOverflowForcesKillAndReapsTERMIgnoringHelper() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        let marker = fixture.root.appendingPathComponent("overflow-pid")
        try fixture.createExecutable(
            at: helper,
            contents: termIgnoringHelperScript(marker: marker, emitsOutput: true)
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))
        let request = ModelBridgeRequest.discover(
            id: 44,
            provider: .ollama,
            timeoutMilliseconds: 3_000
        )

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: ModelBridgeClientError.responseTooLarge) {
            try await client.send(request)
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(!processExists(try helperPID(from: marker)))
    }

    @Test
    func cancellingSendForcesKillAndReapsTERMIgnoringHelper() async throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("localocr-model-bridge")
        let marker = fixture.root.appendingPathComponent("started")
        try fixture.createExecutable(
            at: helper,
            contents: termIgnoringHelperScript(marker: marker, emitsOutput: false)
        )
        let client = StdioModelBridgeClient(executableLocator: FixedExecutableLocator(url: helper))
        let task = Task {
            try await client.send(.discover(id: 44, provider: .ollama))
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation should not produce a response.")
        } catch is CancellationError {
            // Expected.
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(!processExists(try helperPID(from: marker)))
    }
}

private final class FailingIfCalledLocator: ModelBridgeExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func executableURL() throws -> URL {
        lock.withLock { calls += 1 }
        throw CocoaError(.fileNoSuchFile)
    }
}

private struct FixedExecutableLocator: ModelBridgeExecutableLocating {
    let url: URL

    func executableURL() throws -> URL {
        url
    }
}

private struct ExecutableFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("localocr-model-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func createExecutable(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    func createResponseHelper(_ responseLine: String) throws -> URL {
        let helper = root.appendingPathComponent("localocr-model-bridge")
        try createExecutable(
            at: helper,
            contents: """
            #!/bin/sh
            IFS= read -r request
            printf '%s\\n' '\(responseLine)'
            """
        )
        return helper
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let fixtureGenerateRequest = ModelBridgeRequest.generate(
    id: 44,
    expectedIdentity: LocalModelIdentity(
        provider: .ollama,
        model: "gemma4:8b",
        fingerprint: "sha256:fixture",
        harnessVersion: "0.11.7"
    ),
    operation: .summarize,
    prompt: "Summarize grounded OCR text."
)

private func termIgnoringHelperScript(marker: URL, emitsOutput: Bool) -> String {
    let outputLoop = emitsOutput
        ? "my $chunk = 'A' x 4096; while (1) { print STDOUT $chunk; }"
        : "while (1) {}"
    return """
    #!/usr/bin/perl
    use strict;
    use warnings;
    $SIG{'TERM'} = 'IGNORE';
    $SIG{'ALRM'} = sub { exit 0; };
    alarm 4;
    open my $marker, '>', q{\(marker.path)} or die;
    print $marker $$;
    close $marker;
    $| = 1;
    \(outputLoop)
    """
}

private func helperPID(from marker: URL) throws -> pid_t {
    let value = try String(contentsOf: marker, encoding: .utf8)
    return try #require(pid_t(value))
}

private func processExists(_ processID: pid_t) -> Bool {
    if Darwin.kill(processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

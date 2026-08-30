import Darwin
import Foundation
@testable import LocalOCRModelBridgeKit
import Testing

@Suite("Fixed LM Studio CLI probe", .serialized)
struct LMStudioCLIProbeTests {
    @Test
    func fixedCommandsParseDisabledLinkAndLocalDownloadedModel() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }
        let probe = LMStudioCLIProbe(homeDirectory: fixture.homeDirectory)

        let link = try await probe.linkStatus()
        let models = try await probe.localModels()
        let version = try await probe.version()

        #expect(link == LMStudioLinkStatus(enabled: false, connectedPeerCount: 0))
        #expect(models == [fixtureLocalModel])
        #expect(version == "fixture-commit")
        #expect(try fixture.recordedArguments() == [
            "link status --json",
            "ls --llm --json",
            "--version"
        ])
    }

    @Test
    func fullSnapshotRunsLinkLastAndKeepsAllEvidenceTogether() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }

        let snapshot = try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).snapshot()

        #expect(snapshot.version == "fixture-commit")
        #expect(snapshot.models.count == 1)
        #expect(snapshot.link == LMStudioLinkStatus(enabled: false, connectedPeerCount: 0))
        #expect(try fixture.recordedArguments() == [
            "--version", "ls --llm --json", "link status --json"
        ])
    }

    @Test
    func missingExecutableIsRejectedWithoutConsultingPATH() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmstudio-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        await #expect(throws: LMStudioCLIProbeError.missingExecutable) {
            try await LMStudioCLIProbe(homeDirectory: home).version()
        }
    }

    @Test
    func executableSymlinkEscapingPhysicalBinIsRejected() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            executableOutsideBin: true
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.unsafeExecutable) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).version()
        }
        #expect(try fixture.recordedArguments().isEmpty)
    }

    @Test
    func executableReplacementOrSymlinkSwapDuringInvocationFailsClosed() async throws {
        for swap in [ExecutableSwap.replacement, .escapingSymlink] {
            let fixture = try LMStudioExecutableFixture(
                linkJSON: disabledLinkJSON,
                modelsJSON: downloadedModelsJSON,
                versionOutput: "CLI commit: fixture-commit",
                executableSwap: swap
            )
            defer { fixture.remove() }

            await #expect(throws: LMStudioCLIProbeError.unsafeExecutable) {
                try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).version()
            }
        }
    }

    @Test
    func envInterpreterShebangIsRejectedWithoutPATHLookup() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            usesEnvironmentShebang: true
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.unsafeExecutable) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).version()
        }
    }

    @Test
    func childReceivesOnlyFixedHomeAndNoInheritedSensitiveEnvironment() async throws {
        let sentinelName = "LOCALOCR_LMSTUDIO_SENTINEL"
        let oldSentinel = getenv(sentinelName).map { String(cString: $0) }
        setenv(sentinelName, "must-not-leak", 1)
        defer {
            if let oldSentinel {
                setenv(sentinelName, oldSentinel, 1)
            } else {
                unsetenv(sentinelName)
            }
        }
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            recordsEnvironment: true
        )
        defer { fixture.remove() }

        _ = try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).version()

        let environment = try fixture.recordedEnvironment()
        #expect(environment == [
            "HOME=\(fixture.homeDirectory.path)",
            "PATH=",
            "HTTP_PROXY=unset",
            "HTTPS_PROXY=unset",
            "ALL_PROXY=unset",
            "DYLD_INSERT_LIBRARIES=unset",
            "SENTINEL=unset"
        ])
    }

    @Test
    func remoteDownloadedModelRowIsPreservedAsConflictingEvidence() async throws {
        let remoteModels = downloadedModelsJSON.replacingOccurrences(
            of: #""deviceIdentifier":null"#,
            with: #""deviceIdentifier":"remote-device""#
        )
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: remoteModels,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }

        let models = try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).localModels()

        #expect(models.count == 1)
    }

    @Test
    func missingDeviceIdentifierCannotBeMistakenForLocalEvidence() async throws {
        let missingLocalityMarker = downloadedModelsJSON.replacingOccurrences(
            of: #""deviceIdentifier":null,"#,
            with: ""
        )
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: missingLocalityMarker,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).localModels()
        }
    }

    @Test
    func unknownLinkIssueAndIncompleteModelEvidenceAreRejected() async throws {
        let invalidLink = disabledLinkJSON.replacingOccurrences(
            of: #""deviceDisabled""#,
            with: #""futureUnknownIssue""#
        )
        let incompleteModels = #"[{"type":"llm","modelKey":"model"}]"#
        let invalidLinkFixture = try LMStudioExecutableFixture(
            linkJSON: invalidLink,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit"
        )
        let invalidModelsFixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: incompleteModels,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer {
            invalidLinkFixture.remove()
            invalidModelsFixture.remove()
        }

        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: invalidLinkFixture.homeDirectory).linkStatus()
        }
        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: invalidModelsFixture.homeDirectory).localModels()
        }
    }

    @Test
    func versionWithExtraLinesIsMalformedEvidence() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit\n\n"
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).version()
        }
    }

    @Test
    func contradictoryDisabledLinkEvidenceIsRejected() async throws {
        let contradictoryLink = disabledLinkJSON
            .replacingOccurrences(of: #""status":"offline""#, with: #""status":"online""#)
        let fixture = try LMStudioExecutableFixture(
            linkJSON: contradictoryLink,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).linkStatus()
        }
    }

    @Test
    func missingLinkDeviceIdentifierIsMalformedEvidence() async throws {
        let missingDeviceMarker = disabledLinkJSON.replacingOccurrences(
            of: #","deviceIdentifier":null"#,
            with: ""
        )
        let fixture = try LMStudioExecutableFixture(
            linkJSON: missingDeviceMarker,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit"
        )
        defer { fixture.remove() }

        await #expect(throws: LMStudioCLIProbeError.invalidOutput) {
            try await LMStudioCLIProbe(homeDirectory: fixture.homeDirectory).linkStatus()
        }
    }

    @Test
    func stdoutAndStderrAreIndependentlyBounded() async throws {
        let stdoutFixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            oversizedStream: .stdout
        )
        let stderrFixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            oversizedStream: .stderr
        )
        defer {
            stdoutFixture.remove()
            stderrFixture.remove()
        }

        await #expect(throws: LMStudioCLIProbeError.outputTooLarge) {
            try await LMStudioCLIProbe(homeDirectory: stdoutFixture.homeDirectory).version()
        }
        await #expect(throws: LMStudioCLIProbeError.outputTooLarge) {
            try await LMStudioCLIProbe(homeDirectory: stderrFixture.homeDirectory).version()
        }
    }

    @Test
    func timeoutEscalatesFromTERMToKILLAndReapsProcess() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            hangsIgnoringTERM: true
        )
        defer { fixture.remove() }
        let probe = LMStudioCLIProbe(
            homeDirectory: fixture.homeDirectory,
            commandTimeout: .milliseconds(500),
            terminationGracePeriod: .milliseconds(100)
        )

        await #expect(throws: LMStudioCLIProbeError.timedOut) {
            try await probe.version()
        }

        let pid = Int32(try fixture.recordedPID())
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func timeoutKillsAndReapsTheEntireIsolatedProcessGroupWithinBudget() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            processTree: .hang
        )
        defer { fixture.remove() }
        let probe = LMStudioCLIProbe(
            homeDirectory: fixture.homeDirectory,
            commandTimeout: .milliseconds(250),
            terminationGracePeriod: .milliseconds(100)
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LMStudioCLIProbeError.timedOut) {
            try await probe.version()
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
        try assertProcessAndGroupAreGone(
            processID: Int32(try fixture.recordedPID()),
            descendantID: Int32(try fixture.recordedDescendantPID())
        )
    }

    @Test
    func outputOverflowKillsTheEntireProcessGroupBeforeCommandTimeout() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            processTree: .flood
        )
        defer { fixture.remove() }
        let probe = LMStudioCLIProbe(
            homeDirectory: fixture.homeDirectory,
            commandTimeout: .seconds(2),
            terminationGracePeriod: .milliseconds(100)
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LMStudioCLIProbeError.outputTooLarge) {
            try await probe.version()
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
        try assertProcessAndGroupAreGone(
            processID: Int32(try fixture.recordedPID()),
            descendantID: Int32(try fixture.recordedDescendantPID())
        )
    }

    @Test
    func cancellationKillsTheEntireProcessGroupAndReturnsPromptly() async throws {
        let fixture = try LMStudioExecutableFixture(
            linkJSON: disabledLinkJSON,
            modelsJSON: downloadedModelsJSON,
            versionOutput: "CLI commit: fixture-commit",
            processTree: .hang
        )
        defer { fixture.remove() }
        let probe = LMStudioCLIProbe(
            homeDirectory: fixture.homeDirectory,
            commandTimeout: .seconds(2),
            terminationGracePeriod: .milliseconds(100)
        )
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await probe.version() }
        try await Task.sleep(for: .milliseconds(100))

        task.cancel()

        await #expect(throws: LMStudioCLIProbeError.cancelled) {
            try await task.value
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
        try assertProcessAndGroupAreGone(
            processID: Int32(try fixture.recordedPID()),
            descendantID: Int32(try fixture.recordedDescendantPID())
        )
    }
}

private func assertProcessAndGroupAreGone(
    processID: Int32,
    descendantID: Int32
) throws {
    for target in [processID, descendantID, -processID] {
        errno = 0
        #expect(kill(target, 0) == -1)
        #expect(errno == ESRCH)
    }
}

let disabledLinkJSON = #"{"status":"offline","issues":["deviceDisabled"],"peers":[],"deviceIdentifier":null,"deviceName":"This Mac"}"#

let downloadedModelsJSON = #"[{"type":"llm","modelKey":"lmstudio-community/gemma-3-4b-it-GGUF","format":"gguf","displayName":"Gemma 3 4B IT","publisher":"lmstudio-community","path":"lmstudio-community/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf","sizeBytes":4294967296,"indexedModelIdentifier":"lmstudio-community/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"4B","architecture":"gemma3","quantization":{"name":"Q4_K_M","bits":4},"variants":["lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"],"selectedVariant":"lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m","vision":false,"trainedForToolUse":false,"maxContextLength":131072}]"#

private let fixtureLocalModel = LMStudioLocalModel(
    key: "lmstudio-community/gemma-3-4b-it-GGUF",
    selectedVariant: "lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m",
    architecture: "gemma3",
    format: "gguf",
    quantization: "Q4_K_M",
    sizeBytes: 4_294_967_296
)

enum OversizedStream {
    case stdout
    case stderr
}

enum ExecutableSwap {
    case replacement
    case escapingSymlink
}

enum ProcessTreeFixture {
    case hang
    case flood
}

struct LMStudioExecutableFixture {
    let root: URL
    let homeDirectory: URL
    private let argumentsURL: URL
    private let pidURL: URL
    private let descendantPIDURL: URL
    private let environmentURL: URL

    init(
        linkJSON: String,
        modelsJSON: String,
        versionOutput: String,
        executableOutsideBin: Bool = false,
        oversizedStream: OversizedStream? = nil,
        hangsIgnoringTERM: Bool = false,
        executableSwap: ExecutableSwap? = nil,
        usesEnvironmentShebang: Bool = false,
        recordsEnvironment: Bool = false,
        processTree: ProcessTreeFixture? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmstudio-cli-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let bin = homeDirectory.appendingPathComponent(".lmstudio/bin", isDirectory: true)
        argumentsURL = root.appendingPathComponent("arguments.txt")
        pidURL = root.appendingPathComponent("pid.txt")
        descendantPIDURL = root.appendingPathComponent("descendant-pid.txt")
        environmentURL = root.appendingPathComponent("environment.txt")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: argumentsURL)

        let physicalExecutable: URL
        if executableOutsideBin {
            physicalExecutable = root.appendingPathComponent("outside-lms")
        } else {
            physicalExecutable = bin.appendingPathComponent("lms")
        }
        let streamCommand = switch oversizedStream {
        case .stdout?: "i=0; while [ $i -lt 12000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done"
        case .stderr?: "i=0; while [ $i -lt 12000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done"
        case nil: ":"
        }
        let hangCommand = hangsIgnoringTERM
            ? "printf '%s\\n' \"$$\" > '\(Self.shellEscaped(pidURL.path))'; trap '' TERM; exec /bin/sleep 30"
            : ":"
        let processTreeCommand = switch processTree {
        case .hang?: """
        printf '%s\\n' "$$" > '\(Self.shellEscaped(pidURL.path))'
        trap '' TERM
        (trap '' TERM; /bin/sleep 3) &
        printf '%s\\n' "$!" > '\(Self.shellEscaped(descendantPIDURL.path))'
        while :; do /bin/sleep 3; done
        """
        case .flood?: """
        printf '%s\\n' "$$" > '\(Self.shellEscaped(pidURL.path))'
        trap '' TERM
        (trap '' TERM; /bin/sleep 3) &
        printf '%s\\n' "$!" > '\(Self.shellEscaped(descendantPIDURL.path))'
        while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done
        """
        case nil: ":"
        }
        let environmentCommand = recordsEnvironment ? """
        printf '%s\\n' \\
          "HOME=${HOME-unset}" \\
          "PATH=${PATH-unset}" \\
          "HTTP_PROXY=${HTTP_PROXY-unset}" \\
          "HTTPS_PROXY=${HTTPS_PROXY-unset}" \\
          "ALL_PROXY=${ALL_PROXY-unset}" \\
          "DYLD_INSERT_LIBRARIES=${DYLD_INSERT_LIBRARIES-unset}" \\
          "SENTINEL=${LOCALOCR_LMSTUDIO_SENTINEL-unset}" \\
          > '\(Self.shellEscaped(environmentURL.path))'
        """ : ":"
        let replacementURL = root.appendingPathComponent("replacement-lms")
        let escapingURL = root.appendingPathComponent("escaping-lms")
        let replacementScript = "#!/bin/sh\\nprintf '%s\\n' 'CLI commit: replacement'\\n"
        try Data(replacementScript.utf8).write(to: replacementURL)
        try Data(replacementScript.utf8).write(to: escapingURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: escapingURL.path)
        let swapCommand = switch executableSwap {
        case .replacement?: "/bin/mv -f '\(Self.shellEscaped(replacementURL.path))' '\(Self.shellEscaped(physicalExecutable.path))'"
        case .escapingSymlink?: "/bin/rm -f '\(Self.shellEscaped(physicalExecutable.path))'; /bin/ln -s '\(Self.shellEscaped(escapingURL.path))' '\(Self.shellEscaped(physicalExecutable.path))'"
        case nil: ":"
        }
        let shebang = usesEnvironmentShebang ? "#!/usr/bin/env sh" : "#!/bin/sh"
        let script = """
        \(shebang)
        printf '%s\\n' "$*" >> '\(Self.shellEscaped(argumentsURL.path))'
        if [ "$*" = "--version" ]; then
          \(environmentCommand)
          \(swapCommand)
          \(streamCommand)
          \(hangCommand)
          \(processTreeCommand)
        fi
        case "$*" in
          "link status --json") printf '%s\\n' '\(Self.shellEscaped(linkJSON))' ;;
          "ls --llm --json") printf '%s\\n' '\(Self.shellEscaped(modelsJSON))' ;;
          "--version") printf '%s\\n' '\(Self.shellEscaped(versionOutput))' ;;
          *) exit 88 ;;
        esac
        """
        try Data(script.utf8).write(to: physicalExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: physicalExecutable.path
        )
        if executableOutsideBin {
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent("lms"),
                withDestinationURL: physicalExecutable
            )
        }
    }

    func recordedArguments() throws -> [String] {
        let data = try Data(contentsOf: argumentsURL)
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    func recordedPID() throws -> Int {
        let data = try Data(contentsOf: pidURL)
        return try #require(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func recordedDescendantPID() throws -> Int {
        let data = try Data(contentsOf: descendantPIDURL)
        return try #require(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func recordedEnvironment() throws -> [String] {
        let data = try Data(contentsOf: environmentURL)
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

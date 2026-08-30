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

    @Test
    func pinnedDescriptorExecutesOriginalAcrossPathSwapAndRestore() async throws {
        let fixture = try FDStableExecutionFixture()
        defer { fixture.remove() }
        let pinnedFD = Darwin.open(fixture.executableURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(pinnedFD >= 0)
        defer { Darwin.close(pinnedFD) }
        try fixture.installReplacementAtExecutablePath()
        let runner = LMStudioCommandRunner(
            commandTimeout: .seconds(1),
            terminationGracePeriod: .milliseconds(50),
            cleanupBudget: .milliseconds(500),
            pipeDrainBudget: .milliseconds(100),
            maximumOutputBytes: 1_048_576
        )
        let task = Task {
            try await runner.run(
                executableDescriptor: pinnedFD,
                displayPath: fixture.executableURL.path,
                arguments: ["--version"],
                environment: ["HOME=\(fixture.root.path)", "PATH="]
            )
        }
        try await fixture.waitUntilEitherExecutableStarts()

        try fixture.restoreOriginalExecutablePath()
        let output = try await task.value

        #expect(String(decoding: output, as: UTF8.self) == "CLI commit: original\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.replacementExecutedURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.originalExecutedURL.path))
    }

    @Test
    func arm64MachOCLIExecutesOnlyAfterSuspendedIdentityMatch() async throws {
        let fixture = try MachOExecutionFixture()
        defer { fixture.remove() }
        let pinnedFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(pinnedFD >= 0)
        defer { Darwin.close(pinnedFD) }

        let output = try await fixture.runner().run(
            executableDescriptor: pinnedFD,
            displayPath: fixture.executableURL.path,
            arguments: ["--version"],
            environment: ["HOME=\(fixture.root.path)", "PATH="]
        )

        #expect(String(decoding: output, as: UTF8.self) == "CLI commit: original-mach-o\n")
        #expect(FileManager.default.fileExists(atPath: fixture.originalExecutedURL.path))
    }

    @Test
    func suspendedMachOPathABAStillRejectsTheLoadedReplacementCode() async throws {
        let fixture = try MachOExecutionFixture()
        defer { fixture.remove() }
        let pinnedFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(pinnedFD >= 0)
        defer { Darwin.close(pinnedFD) }
        try fixture.installReplacementAtExecutablePath()
        let runner = fixture.runner(
            suspendedCodeInspector: ABASuspendedCodeInspector(fixture: fixture)
        )
        let task = Task {
            try await runner.run(
                executableDescriptor: pinnedFD,
                displayPath: fixture.executableURL.path,
                arguments: ["--version"],
                environment: ["HOME=\(fixture.root.path)", "PATH="]
            )
        }
        try await fixture.waitUntilSuspendedInspectionStarts()

        try fixture.restoreOriginalExecutablePath()
        try fixture.releaseSuspendedInspection()
        try await fixture.waitUntilSuspendedCodeIsBound()
        try fixture.reinstallReplacementAtExecutablePath()
        try fixture.releaseSuspendedCodeInspection()

        await #expect(throws: LMStudioCLIProbeError.unsafeExecutable) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.replacementExecutedURL.path))
        let childPID = try fixture.suspendedProcessID()
        for target in [childPID, -childPID] {
            errno = 0
            #expect(kill(target, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test
    func arm64MachOChildDoesNotInheritPinnedExecutableDescriptor() async throws {
        let fixture = try MachOExecutionFixture(rejectsInheritedDescriptors: true)
        defer { fixture.remove() }
        let pinnedFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(pinnedFD >= 0)
        defer { Darwin.close(pinnedFD) }

        let output = try await fixture.runner().run(
            executableDescriptor: pinnedFD,
            displayPath: fixture.executableURL.path,
            arguments: ["--version"],
            environment: ["HOME=\(fixture.root.path)", "PATH="]
        )

        #expect(String(decoding: output, as: UTF8.self) == "CLI commit: original-mach-o\n")
    }

    @Test
    func suspendedCodeInspectionConsumesTheHardCommandDeadline() async throws {
        let fixture = try MachOExecutionFixture()
        defer { fixture.remove() }
        let pinnedFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(pinnedFD >= 0)
        defer { Darwin.close(pinnedFD) }
        let runner = fixture.runner(
            timeout: .milliseconds(50),
            suspendedCodeInspector: DelayedSuspendedCodeInspector(delay: .milliseconds(100))
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LMStudioCLIProbeError.timedOut) {
            try await runner.run(
                executableDescriptor: pinnedFD,
                displayPath: fixture.executableURL.path,
                arguments: ["--version"],
                environment: ["HOME=\(fixture.root.path)", "PATH="]
            )
        }

        #expect(start.duration(to: clock.now) < .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: fixture.originalExecutedURL.path))
    }

    @Test
    func childCannotObserveUnrelatedOpenParentDescriptor() async throws {
        let fixture = try RunnerScriptFixture()
        defer { fixture.remove() }
        let sentinelURL = fixture.root.appendingPathComponent("sentinel")
        try Data("secret".utf8).write(to: sentinelURL)
        let sentinelFD = Darwin.open(sentinelURL.path, O_RDONLY)
        #expect(sentinelFD >= 0)
        #expect(fcntl(sentinelFD, F_GETFD) & FD_CLOEXEC == 0)
        defer { Darwin.close(sentinelFD) }
        try fixture.writeScript("""
        #!/bin/sh
        if [ -e '/dev/fd/\(sentinelFD)' ]; then
          printf 'leaked\\n'
        else
          printf 'closed\\n'
        fi
        """)
        let executableFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(executableFD >= 0)
        defer { Darwin.close(executableFD) }

        let output = try await fixture.runner().run(
            executableDescriptor: executableFD,
            displayPath: fixture.executableURL.path,
            arguments: ["--version"],
            environment: ["HOME=\(fixture.root.path)", "PATH="]
        )

        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
    }

    @Test
    func cleanupFailureIsBoundedAndSurfacesStableError() async {
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LMStudioCLIProbeError.commandFailed) {
            try await LMStudioProcessGroupCleanup.terminateAndReap(
                pid: 4_242,
                currentStatus: nil,
                gracePeriod: .milliseconds(10),
                cleanupBudget: .milliseconds(50),
                system: NeverDisappearingProcessSystem()
            )
        }

        #expect(start.duration(to: clock.now) < .milliseconds(250))
    }

    @Test
    func descendantRefreshFailureStillKillsAndReapsOwnedGroup() async throws {
        try await assertObserverFailureStillCleansOwnedGroup(
            tracker: RefreshFailingDescendantTracker()
        )
    }

    @Test
    func descendantAmbiguityStillKillsAndReapsOwnedGroup() async throws {
        try await assertObserverFailureStillCleansOwnedGroup(
            tracker: AmbiguousDescendantTracker()
        )
    }

    @Test
    func observedDescendantPIDReuseCannotSignalTheReplacementProcess() throws {
        let observer = ReusedPIDProcessObserver()
        let tracker = try DarwinLMStudioDescendantTracker(
            rootPID: observer.root.pid,
            observer: observer
        )
        try tracker.refresh()
        observer.replaceChildAtSamePID()

        try tracker.sendSignalToObservedDescendants(SIGKILL)

        #expect(observer.replacementWasSignaled == false)
    }

    @Test
    func immediateUnobservableEscapeFailsClosedWithoutClaimingContainment() async throws {
        let fixture = try EscapedPipeExecutionFixture()
        defer { fixture.remove() }
        let executableFD = Darwin.open(
            fixture.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(executableFD >= 0)
        defer { Darwin.close(executableFD) }
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LMStudioCLIProbeError.commandFailed) {
            try await fixture.runner().run(
                executableDescriptor: executableFD,
                displayPath: fixture.executableURL.path,
                arguments: ["--version"],
                environment: ["HOME=\(fixture.root.path)", "PATH="]
            )
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
        let escapedPID = try fixture.escapedProcessID()
        #expect(kill(escapedPID, 0) == 0)
        defer {
            _ = kill(escapedPID, SIGKILL)
            _ = kill(-escapedPID, SIGKILL)
        }
        var reusePipes = try makeNonblockingReusePipes(count: 64)
        defer { closeReusePipes(&reusePipes) }
        for pipe in reusePipes {
            var byte: UInt8 = 0x5A
            #expect(Darwin.write(pipe.write, &byte, 1) == 1)
        }
        try await Task.sleep(for: .milliseconds(100))

        for pipe in reusePipes {
            var byte: UInt8 = 0
            #expect(Darwin.read(pipe.read, &byte, 1) == 1)
            #expect(byte == 0x5A)
        }
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

private struct NeverDisappearingProcessSystem: LMStudioProcessSystemCalling {
    func sendSignal(_ signal: Int32, toProcessGroup pid: pid_t) throws {}
    func pollStatus(of pid: pid_t) throws -> Int32? { 0 }
    func processGroupExists(_ pid: pid_t) throws -> Bool { true }
}

private enum RunnerFixtureError: Error {
    case setupFailed
    case executableDidNotStart
}

private func assertObserverFailureStillCleansOwnedGroup(
    tracker: any LMStudioDescendantTracking
) async throws {
    let fixture = try OwnedGroupExecutionFixture()
    defer { fixture.remove() }
    let executableFD = Darwin.open(
        fixture.executableURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    #expect(executableFD >= 0)
    defer { Darwin.close(executableFD) }
    let runner = fixture.runner(descendantTracker: tracker)
    let task = Task {
        try await runner.run(
            executableDescriptor: executableFD,
            displayPath: fixture.executableURL.path,
            arguments: ["--version"],
            environment: ["HOME=\(fixture.root.path)", "PATH="]
        )
    }
    try await fixture.waitUntilStarted()
    let processID = try fixture.processID()
    let descendantID = try fixture.descendantID()
    defer {
        _ = kill(-processID, SIGKILL)
        _ = kill(processID, SIGKILL)
        _ = kill(descendantID, SIGKILL)
    }

    await #expect(throws: LMStudioCLIProbeError.commandFailed) {
        try await task.value
    }

    try assertProcessAndGroupAreGone(
        processID: processID,
        descendantID: descendantID
    )
}

private final class RefreshFailingDescendantTracker: LMStudioDescendantTracking,
    @unchecked Sendable {
    func refresh() throws { throw LMStudioCLIProbeError.commandFailed }
    func sendSignalToObservedDescendants(_ signal: Int32) throws {}
    func allGone() throws -> Bool { throw LMStudioCLIProbeError.commandFailed }
}

private final class AmbiguousDescendantTracker: LMStudioDescendantTracking,
    @unchecked Sendable {
    func refresh() throws {}
    func sendSignalToObservedDescendants(_ signal: Int32) throws {
        throw LMStudioCLIProbeError.commandFailed
    }
    func allGone() throws -> Bool { throw LMStudioCLIProbeError.commandFailed }
}

private final class ReusedPIDProcessObserver: LMStudioProcessIdentityObserving,
    @unchecked Sendable {
    let root = LMStudioObservedProcessIdentity(
        pid: 40_001,
        owner: getuid(),
        uniqueID: 100,
        parentUniqueID: 99,
        pidVersion: 10
    )
    private let originalChild = LMStudioObservedProcessIdentity(
        pid: 40_002,
        owner: getuid(),
        uniqueID: 101,
        parentUniqueID: 100,
        pidVersion: 11
    )
    private var currentChild: LMStudioObservedProcessIdentity
    private(set) var replacementWasSignaled = false

    init() {
        currentChild = originalChild
    }

    func identity(of pid: pid_t) throws -> LMStudioObservedProcessIdentity? {
        if pid == root.pid { return root }
        if pid == currentChild.pid { return currentChild }
        return nil
    }

    func childIdentities(
        of parent: LMStudioObservedProcessIdentity
    ) throws -> [LMStudioObservedProcessIdentity] {
        parent == root && currentChild == originalChild ? [originalChild] : []
    }

    func sendSignal(
        _ signal: Int32,
        to identity: LMStudioObservedProcessIdentity
    ) throws -> Bool {
        if identity.pid == currentChild.pid, identity != currentChild {
            return false
        }
        if identity == currentChild { replacementWasSignaled = true }
        return true
    }

    func replaceChildAtSamePID() {
        currentChild = LMStudioObservedProcessIdentity(
            pid: originalChild.pid,
            owner: getuid(),
            uniqueID: 202,
            parentUniqueID: 201,
            pidVersion: 22
        )
    }
}

private struct OwnedGroupExecutionFixture {
    let scriptFixture: RunnerScriptFixture
    let processIDURL: URL
    let descendantIDURL: URL

    var root: URL { scriptFixture.root }
    var executableURL: URL { scriptFixture.executableURL }

    init() throws {
        let fixture = try RunnerScriptFixture(prefix: "lmstudio-owned-group")
        scriptFixture = fixture
        processIDURL = fixture.root.appendingPathComponent("process.pid")
        descendantIDURL = fixture.root.appendingPathComponent("descendant.pid")
        try fixture.writeScript("""
        #!/bin/sh
        printf '%s\n' "$$" > '\(Self.shellEscaped(processIDURL.path))'
        trap '' TERM
        (trap '' TERM; exec /bin/sleep 30) &
        printf '%s\n' "$!" > '\(Self.shellEscaped(descendantIDURL.path))'
        while :; do /bin/sleep 30; done
        """)
    }

    func runner(descendantTracker: any LMStudioDescendantTracking) -> LMStudioCommandRunner {
        LMStudioCommandRunner(
            commandTimeout: .milliseconds(100),
            terminationGracePeriod: .milliseconds(20),
            cleanupBudget: .milliseconds(300),
            pipeDrainBudget: .milliseconds(100),
            maximumOutputBytes: 1_048_576,
            descendantTrackerFactory: { _ in descendantTracker }
        )
    }

    func waitUntilStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: processIDURL.path),
               FileManager.default.fileExists(atPath: descendantIDURL.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RunnerFixtureError.executableDidNotStart
    }

    func processID() throws -> pid_t { try readPID(processIDURL) }
    func descendantID() throws -> pid_t { try readPID(descendantIDURL) }
    func remove() { scriptFixture.remove() }

    private func readPID(_ url: URL) throws -> pid_t {
        let data = try Data(contentsOf: url)
        guard let pid = Int32(
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RunnerFixtureError.setupFailed
        }
        return pid
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private struct RunnerScriptFixture {
    let root: URL
    let executableURL: URL

    init(prefix: String = "lmstudio-runner") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        executableURL = root.appendingPathComponent("lms")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeScript(_ script: String) throws {
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func runner(
        timeout: Duration = .seconds(1),
        cleanupBudget: Duration = .milliseconds(500),
        pipeDrainBudget: Duration = .milliseconds(100)
    ) -> LMStudioCommandRunner {
        LMStudioCommandRunner(
            commandTimeout: timeout,
            terminationGracePeriod: .milliseconds(50),
            cleanupBudget: cleanupBudget,
            pipeDrainBudget: pipeDrainBudget,
            maximumOutputBytes: 1_048_576
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ABASuspendedCodeInspector: LMStudioSuspendedCodeInspecting {
    let fixture: MachOExecutionFixture

    func codeIdentity(ofSuspendedProcess pid: pid_t) async throws -> ExecutableCodeIdentity {
        try fixture.recordSuspendedInspection(processID: pid)
        try await fixture.waitUntilSuspendedInspectionIsReleased()
        return try await DarwinLMStudioSuspendedCodeInspector {
            try fixture.recordSuspendedCodeIsBound()
            try await fixture.waitUntilSuspendedCodeInspectionIsReleased()
        }
            .codeIdentity(ofSuspendedProcess: pid)
    }
}

private struct DelayedSuspendedCodeInspector: LMStudioSuspendedCodeInspecting {
    let delay: Duration

    func codeIdentity(ofSuspendedProcess pid: pid_t) async throws -> ExecutableCodeIdentity {
        try await Task.sleep(for: delay)
        return try await DarwinLMStudioSuspendedCodeInspector()
            .codeIdentity(ofSuspendedProcess: pid)
    }
}

private struct MachOExecutionFixture {
    let root: URL
    let executableURL: URL
    let originalExecutedURL: URL
    let replacementExecutedURL: URL
    private let originalBackupURL: URL
    private let replacementSourceURL: URL
    private let retiredReplacementURL: URL
    private let inspectionStartedURL: URL
    private let inspectionReleasedURL: URL
    private let suspendedCodeBoundURL: URL
    private let codeInspectionReleasedURL: URL
    private let suspendedPIDURL: URL

    init(rejectsInheritedDescriptors: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmstudio-mach-o-\(UUID().uuidString)", isDirectory: true)
        executableURL = root.appendingPathComponent("lms")
        originalBackupURL = root.appendingPathComponent("original-lms")
        replacementSourceURL = root.appendingPathComponent("replacement-lms")
        retiredReplacementURL = root.appendingPathComponent("retired-replacement-lms")
        originalExecutedURL = root.appendingPathComponent("original-executed")
        replacementExecutedURL = root.appendingPathComponent("replacement-executed")
        inspectionStartedURL = root.appendingPathComponent("inspection-started")
        inspectionReleasedURL = root.appendingPathComponent("inspection-released")
        suspendedCodeBoundURL = root.appendingPathComponent("suspended-code-bound")
        codeInspectionReleasedURL = root.appendingPathComponent("code-inspection-released")
        suspendedPIDURL = root.appendingPathComponent("suspended.pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.compileExecutable(
            at: executableURL,
            marker: originalExecutedURL,
            output: "CLI commit: original-mach-o\n",
            rejectsInheritedDescriptors: rejectsInheritedDescriptors
        )
        try Self.compileExecutable(
            at: replacementSourceURL,
            marker: replacementExecutedURL,
            output: "CLI commit: replacement-mach-o\n",
            rejectsInheritedDescriptors: rejectsInheritedDescriptors
        )
    }

    func runner(
        timeout: Duration = .seconds(1),
        suspendedCodeInspector: any LMStudioSuspendedCodeInspecting =
            DarwinLMStudioSuspendedCodeInspector()
    ) -> LMStudioCommandRunner {
        LMStudioCommandRunner(
            commandTimeout: timeout,
            terminationGracePeriod: .milliseconds(50),
            cleanupBudget: .milliseconds(500),
            pipeDrainBudget: .milliseconds(100),
            maximumOutputBytes: 1_048_576,
            suspendedCodeInspector: suspendedCodeInspector
        )
    }

    func installReplacementAtExecutablePath() throws {
        try FileManager.default.moveItem(at: executableURL, to: originalBackupURL)
        try FileManager.default.moveItem(at: replacementSourceURL, to: executableURL)
    }

    func restoreOriginalExecutablePath() throws {
        try FileManager.default.moveItem(at: executableURL, to: retiredReplacementURL)
        try FileManager.default.moveItem(at: originalBackupURL, to: executableURL)
    }

    func reinstallReplacementAtExecutablePath() throws {
        try FileManager.default.moveItem(at: executableURL, to: originalBackupURL)
        try FileManager.default.moveItem(at: retiredReplacementURL, to: executableURL)
    }

    func recordSuspendedInspection(processID: pid_t) throws {
        try Data("\(processID)\n".utf8).write(to: suspendedPIDURL)
        try Data().write(to: inspectionStartedURL)
    }

    func waitUntilSuspendedInspectionStarts() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: inspectionStartedURL.path),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard FileManager.default.fileExists(atPath: inspectionStartedURL.path) else {
            throw RunnerFixtureError.executableDidNotStart
        }
    }

    func waitUntilSuspendedInspectionIsReleased() async throws {
        try await waitForFile(inspectionReleasedURL)
    }

    func releaseSuspendedInspection() throws {
        try Data().write(to: inspectionReleasedURL)
    }

    func recordSuspendedCodeIsBound() throws {
        try Data().write(to: suspendedCodeBoundURL)
    }

    func waitUntilSuspendedCodeIsBound() async throws {
        try await waitForFile(suspendedCodeBoundURL)
    }

    func releaseSuspendedCodeInspection() throws {
        try Data().write(to: codeInspectionReleasedURL)
    }

    func waitUntilSuspendedCodeInspectionIsReleased() async throws {
        try await waitForFile(codeInspectionReleasedURL)
    }

    func suspendedProcessID() throws -> pid_t {
        let data = try Data(contentsOf: suspendedPIDURL)
        guard let pid = Int32(
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RunnerFixtureError.setupFailed
        }
        return pid
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func compileExecutable(
        at executableURL: URL,
        marker: URL,
        output: String,
        rejectsInheritedDescriptors: Bool
    ) throws {
        let sourceURL = executableURL.appendingPathExtension("c")
        let source = """
        #include <fcntl.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
          if (\(rejectsInheritedDescriptors ? 1 : 0)) {
            for (int fd = 3; fd < 256; fd++) {
              if (fcntl(fd, F_GETFD) >= 0) return 89;
            }
          }
          int marker = open("\(cEscaped(marker.path))", O_WRONLY | O_CREAT | O_TRUNC, 0600);
          if (marker >= 0) { write(marker, "ran", 3); close(marker); }
          if (argc != 2 || strcmp(argv[1], "--version") != 0) return 88;
          write(STDOUT_FILENO, "\(cEscaped(output))", \(output.utf8.count));
          return 0;
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [sourceURL.path, "-arch", "arm64", "-o", executableURL.path]
        compiler.standardInput = FileHandle.nullDevice
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationReason == .exit, compiler.terminationStatus == 0 else {
            throw RunnerFixtureError.setupFailed
        }
    }

    private func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerFixtureError.executableDidNotStart
        }
    }

    private static func cEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private struct FDStableExecutionFixture {
    let scriptFixture: RunnerScriptFixture
    let originalBackupURL: URL
    let replacementExecutedURL: URL
    let originalExecutedURL: URL

    var root: URL { scriptFixture.root }
    var executableURL: URL { scriptFixture.executableURL }

    init() throws {
        let scriptFixture = try RunnerScriptFixture(prefix: "lmstudio-fd-stable")
        self.scriptFixture = scriptFixture
        originalBackupURL = scriptFixture.root.appendingPathComponent("original-lms")
        replacementExecutedURL = scriptFixture.root.appendingPathComponent("replacement-executed")
        originalExecutedURL = scriptFixture.root.appendingPathComponent("original-executed")
        try scriptFixture.writeScript("""
        #!/bin/sh
        printf 'started\\n' > '\(Self.shellEscaped(originalExecutedURL.path))'
        /bin/sleep 0.2
        printf 'CLI commit: original\\n'
        """)
    }

    func installReplacementAtExecutablePath() throws {
        try FileManager.default.moveItem(at: executableURL, to: originalBackupURL)
        let replacement = """
        #!/bin/sh
        printf 'started\\n' > '\(Self.shellEscaped(replacementExecutedURL.path))'
        /bin/sleep 0.2
        printf 'CLI commit: replacement\\n'
        """
        try Data(replacement.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func restoreOriginalExecutablePath() throws {
        try FileManager.default.removeItem(at: executableURL)
        try FileManager.default.moveItem(at: originalBackupURL, to: executableURL)
    }

    func waitUntilEitherExecutableStarts() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: originalExecutedURL.path)
                || FileManager.default.fileExists(atPath: replacementExecutedURL.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RunnerFixtureError.executableDidNotStart
    }

    func remove() { scriptFixture.remove() }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private struct EscapedPipeExecutionFixture {
    let scriptFixture: RunnerScriptFixture
    let escapedPIDURL: URL

    var root: URL { scriptFixture.root }
    var executableURL: URL { scriptFixture.executableURL }

    init() throws {
        let scriptFixture = try RunnerScriptFixture(prefix: "lmstudio-escaped-pipes")
        self.scriptFixture = scriptFixture
        escapedPIDURL = scriptFixture.root.appendingPathComponent("escaped.pid")
        let sourceURL = scriptFixture.root.appendingPathComponent("escape.c")
        let helperURL = scriptFixture.root.appendingPathComponent("escape-helper")
        let cPath = Self.cEscaped(escapedPIDURL.path)
        let source = """
        #include <fcntl.h>
        #include <signal.h>
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
          pid_t child = fork();
          if (child < 0) return 1;
          if (child > 0) return 0;
          if (setsid() < 0) return 2;
          signal(SIGTERM, SIG_IGN);
          signal(SIGPIPE, SIG_IGN);
          int fd = open("\(cPath)", O_WRONLY | O_CREAT | O_TRUNC, 0600);
          if (fd < 0) return 3;
          dprintf(fd, "%d\\n", getpid());
          close(fd);
          usleep(30000000);
          write(STDOUT_FILENO, "late-out", 8);
          write(STDERR_FILENO, "late-err", 8);
          usleep(100000);
          return 0;
        }
        """
        try Data(source.utf8).write(to: sourceURL)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [sourceURL.path, "-o", helperURL.path]
        compiler.standardInput = FileHandle.nullDevice
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationReason == .exit, compiler.terminationStatus == 0 else {
            throw RunnerFixtureError.setupFailed
        }
        try scriptFixture.writeScript("""
        #!/bin/sh
        '\(Self.shellEscaped(helperURL.path))' &
        trap '' TERM
        while :; do /bin/sleep 3; done
        """)
    }

    func runner() -> LMStudioCommandRunner {
        scriptFixture.runner(
            timeout: .milliseconds(200),
            cleanupBudget: .milliseconds(300),
            pipeDrainBudget: .milliseconds(100)
        )
    }

    func escapedProcessID() throws -> pid_t {
        let data = try Data(contentsOf: escapedPIDURL)
        guard let pid = Int32(
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RunnerFixtureError.setupFailed
        }
        return pid
    }

    func remove() { scriptFixture.remove() }

    private static func cEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private struct ReusePipe {
    let read: Int32
    let write: Int32
}

private func makeNonblockingReusePipes(count: Int) throws -> [ReusePipe] {
    try (0..<count).map { _ in
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw RunnerFixtureError.setupFailed }
        let flags = fcntl(descriptors[0], F_GETFL)
        guard flags >= 0, fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw RunnerFixtureError.setupFailed
        }
        return ReusePipe(read: descriptors[0], write: descriptors[1])
    }
}

private func closeReusePipes(_ pipes: inout [ReusePipe]) {
    for pipe in pipes {
        Darwin.close(pipe.read)
        Darwin.close(pipe.write)
    }
    pipes.removeAll()
}

let disabledLinkJSON = #"{"status":"offline","issues":["deviceDisabled"],"peers":[],"deviceIdentifier":null,"deviceName":"This Mac"}"#

let downloadedModelsJSON = #"[{"type":"llm","modelKey":"lmstudio-community/gemma-3-4b-it-GGUF","format":"gguf","displayName":"Gemma 3 4B IT","publisher":"lmstudio-community","path":"lmstudio-community/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf","sizeBytes":4294967296,"indexedModelIdentifier":"lmstudio-community/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"4B","architecture":"gemma3","quantization":{"name":"Q4_K_M","bits":4},"variants":["lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"],"selectedVariant":"lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m","vision":false,"trainedForToolUse":false,"maxContextLength":131072}]"#

private let fixtureLocalModel = LMStudioLocalModel(
    key: "lmstudio-community/gemma-3-4b-it-GGUF",
    selectedVariant: "lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m",
    variants: ["lmstudio-community/gemma-3-4b-it-GGUF@q4_k_m"],
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

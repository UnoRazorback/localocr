import Darwin
import Foundation
import Testing
@testable import LocalOCRStudioKit

@Suite struct AgentClientCommandRunnerTests {
    @Test func capturesStreamsSeparatelyAndPassesExplicitArgumentsAndEnvironment() async throws {
        let fixture = try RunnerFixture(script: """
        #!/bin/sh
        printf 'out:%s:%s' "$1" "$LOCALOCR_TEST_VALUE"
        printf 'err:%s' "$2" >&2
        """)
        let spec = AgentClientCommandSpec(
            executableURL: fixture.executableURL,
            arguments: ["first value", "second value"],
            environment: ["LOCALOCR_TEST_VALUE": "explicit"]
        )

        let result = try await AgentClientCommandRunner().run(spec, timeout: .seconds(2))

        #expect(result.exitStatus == 0)
        #expect(result.stdoutString == "out:first value:explicit")
        #expect(result.stderrString == "err:second value")
    }

    @Test func capsCombinedOutputAtOneMiB() async throws {
        let fixture = try RunnerFixture(script: """
        #!/bin/sh
        head -c 1048577 /dev/zero
        """)

        await #expect(throws: AgentClientCommandRunnerError.outputTooLarge) {
            try await AgentClientCommandRunner().run(
                AgentClientCommandSpec(
                    executableURL: fixture.executableURL,
                    environment: ["PATH": "/usr/bin:/bin"]
                ),
                timeout: .seconds(10)
            )
        }
    }

    @Test func timeoutTerminatesAndReapsChild() async throws {
        let fixture = try RunnerFixture(script: """
        #!/bin/sh
        printf '%s' "$$" > "$LOCALOCR_PID_FILE"
        while true; do sleep 1; done
        """)
        let pidFile = fixture.root.appendingPathComponent("pid")
        let spec = AgentClientCommandSpec(
            executableURL: fixture.executableURL,
            environment: ["LOCALOCR_PID_FILE": pidFile.path, "PATH": "/usr/bin:/bin"]
        )

        await #expect(throws: AgentClientCommandRunnerError.timedOut) {
            try await AgentClientCommandRunner().run(spec, timeout: .milliseconds(150))
        }

        let pid = try await fixture.waitForPID(in: pidFile)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func cancellationTerminatesAndReapsChild() async throws {
        let fixture = try RunnerFixture(script: """
        #!/bin/sh
        printf '%s' "$$" > "$LOCALOCR_PID_FILE"
        while true; do sleep 1; done
        """)
        let pidFile = fixture.root.appendingPathComponent("pid")
        let spec = AgentClientCommandSpec(
            executableURL: fixture.executableURL,
            environment: ["LOCALOCR_PID_FILE": pidFile.path, "PATH": "/usr/bin:/bin"]
        )
        let task = Task {
            try await AgentClientCommandRunner().run(spec, timeout: .seconds(10))
        }
        let pid = try await fixture.waitForPID(in: pidFile)

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func refusesDirectShellOrEnvironmentDispatcherExecutables() async throws {
        for path in ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"] {
            await #expect(throws: AgentClientCommandRunnerError.refusedExecutable) {
                try await AgentClientCommandRunner().run(
                    AgentClientCommandSpec(executableURL: URL(fileURLWithPath: path)),
                    timeout: .seconds(1)
                )
            }
        }
    }
}

private struct RunnerFixture {
    let root: URL
    let executableURL: URL

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executableURL = root.appendingPathComponent("codex")
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text)
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RunnerFixtureError.pidNotWritten
    }
}

private enum RunnerFixtureError: Error {
    case pidNotWritten
}

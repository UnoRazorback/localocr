import Foundation

public enum AgentClientKind: String, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public enum ClaudeMCPConnectionScope: String, CaseIterable, Equatable, Sendable {
    case local
    case user
}

public struct AgentClientInstallation: Equatable, Identifiable, Sendable {
    public let kind: AgentClientKind
    public let executableURL: URL
    public let displayName: String
    public let version: String?

    public var id: String { "\(kind.rawValue):\(executableURL.path)" }

    public init(
        kind: AgentClientKind,
        executableURL: URL,
        displayName: String,
        version: String? = nil
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.displayName = displayName
        self.version = version
    }
}

public struct AgentClientCommandSpec: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

public enum AgentClientCommandFactory {
    public static func inspect(_ installation: AgentClientInstallation) -> AgentClientCommandSpec {
        spec(installation, arguments: ["mcp", "get", "localocr"])
    }

    public static func connect(
        _ installation: AgentClientInstallation,
        helperURL: URL,
        claudeScope: ClaudeMCPConnectionScope = .local
    ) -> AgentClientCommandSpec {
        let arguments: [String]
        switch installation.kind {
        case .codex:
            arguments = ["mcp", "add", "localocr", "--", helperURL.path]
        case .claudeCode:
            arguments = [
                "mcp", "add", "--transport", "stdio",
                "--scope", claudeScope.rawValue,
                "localocr", "--", helperURL.path,
            ]
        }
        return spec(installation, arguments: arguments)
    }

    public static func disconnect(
        _ installation: AgentClientInstallation,
        claudeScope: ClaudeMCPConnectionScope = .local
    ) -> AgentClientCommandSpec {
        let arguments: [String]
        switch installation.kind {
        case .codex:
            arguments = ["mcp", "remove", "localocr"]
        case .claudeCode:
            arguments = ["mcp", "remove", "--scope", claudeScope.rawValue, "localocr"]
        }
        return spec(installation, arguments: arguments)
    }

    private static func spec(
        _ installation: AgentClientInstallation,
        arguments: [String]
    ) -> AgentClientCommandSpec {
        AgentClientCommandSpec(
            executableURL: installation.executableURL,
            arguments: arguments,
            environment: AgentClientProcessEnvironment.filteredCurrent()
        )
    }
}

public enum AgentClientProcessEnvironment {
    private static let allowedKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH",
        "TMPDIR", "USER", "XDG_CONFIG_HOME",
    ]

    public static func filteredCurrent(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            environment[key].map { (key, $0) }
        })
    }
}

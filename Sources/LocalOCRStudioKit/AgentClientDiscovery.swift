import Foundation

public struct AgentClientDiscoveryCandidate: Equatable, Sendable {
    public let kind: AgentClientKind
    public let executableURL: URL
    public let approvedRootURL: URL
    public let displayName: String
    public let version: String?
    public let minimumVersion: String?

    public init(
        kind: AgentClientKind,
        executableURL: URL,
        approvedRootURL: URL,
        displayName: String,
        version: String? = nil,
        minimumVersion: String? = nil
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.approvedRootURL = approvedRootURL
        self.displayName = displayName
        self.version = version
        self.minimumVersion = minimumVersion
    }
}

public enum AgentClientDiscoveryRejectionReason: Equatable, Sendable {
    case outsideApprovedRoot
    case escapedApprovedRoot
    case missing
    case notExecutable
    case unsupportedVersion
}

public struct AgentClientDiscoveryRejection: Equatable, Sendable {
    public let candidate: AgentClientDiscoveryCandidate
    public let reason: AgentClientDiscoveryRejectionReason

    public init(
        candidate: AgentClientDiscoveryCandidate,
        reason: AgentClientDiscoveryRejectionReason
    ) {
        self.candidate = candidate
        self.reason = reason
    }
}

public struct AgentClientDiscoveryResult: Equatable, Sendable {
    public let installations: [AgentClientInstallation]
    public let rejections: [AgentClientDiscoveryRejection]

    public init(
        installations: [AgentClientInstallation],
        rejections: [AgentClientDiscoveryRejection]
    ) {
        self.installations = installations
        self.rejections = rejections
    }
}

public struct AgentClientDiscovery {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(candidates: [AgentClientDiscoveryCandidate]) -> AgentClientDiscoveryResult {
        var installations: [AgentClientInstallation] = []
        var rejections: [AgentClientDiscoveryRejection] = []
        var acceptedIDs = Set<String>()

        for candidate in candidates {
            if let reason = rejectionReason(for: candidate) {
                rejections.append(AgentClientDiscoveryRejection(candidate: candidate, reason: reason))
                continue
            }

            let resolved = candidate.executableURL.resolvingSymlinksInPath().standardizedFileURL
            let installation = AgentClientInstallation(
                kind: candidate.kind,
                executableURL: resolved,
                displayName: candidate.displayName,
                version: candidate.version
            )
            guard acceptedIDs.insert(installation.id).inserted else { continue }
            installations.append(installation)
        }

        return AgentClientDiscoveryResult(installations: installations, rejections: rejections)
    }

    public func discoverInstalledClients(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentClientDiscoveryResult {
        discover(candidates: Self.defaultCandidates(environment: environment, homeDirectory: homeDirectory))
    }

    public static func defaultCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AgentClientDiscoveryCandidate] {
        var candidates: [AgentClientDiscoveryCandidate] = []

        candidates.append(contentsOf: [
            appCandidate(
                kind: .codex,
                executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                bundlePath: "/Applications/Codex.app"
            ),
            appCandidate(
                kind: .codex,
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                bundlePath: "/Applications/ChatGPT.app"
            ),
            appCandidate(
                kind: .claudeCode,
                executablePath: "/Applications/cmux.app/Contents/Resources/bin/claude",
                bundlePath: "/Applications/cmux.app"
            ),
        ])

        let literalDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }

        for directory in literalDirectories {
            let approvedRoot = approvedRoot(forExecutableDirectory: directory, homeDirectory: homeDirectory)
            for kind in AgentClientKind.allCases {
                let binaryName = kind == .codex ? "codex" : "claude"
                candidates.append(AgentClientDiscoveryCandidate(
                    kind: kind,
                    executableURL: directory.appendingPathComponent(binaryName),
                    approvedRootURL: approvedRoot,
                    displayName: kind.displayName
                ))
            }
        }
        return candidates
    }

    private func rejectionReason(
        for candidate: AgentClientDiscoveryCandidate
    ) -> AgentClientDiscoveryRejectionReason? {
        let requested = candidate.executableURL.standardizedFileURL
        let root = candidate.approvedRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(requested, of: root) else { return .outsideApprovedRoot }
        guard fileManager.fileExists(atPath: requested.path) else { return .missing }

        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(resolved, of: root) else { return .escapedApprovedRoot }
        guard fileManager.isExecutableFile(atPath: resolved.path) else { return .notExecutable }

        if let version = candidate.version,
           let minimumVersion = candidate.minimumVersion,
           Self.compareVersions(version, minimumVersion) == .orderedAscending
        {
            return .unsupportedVersion
        }
        return nil
    }

    private static func appCandidate(
        kind: AgentClientKind,
        executablePath: String,
        bundlePath: String
    ) -> AgentClientDiscoveryCandidate {
        let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let version = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AgentClientDiscoveryCandidate(
            kind: kind,
            executableURL: URL(fileURLWithPath: executablePath),
            approvedRootURL: bundleURL,
            displayName: kind.displayName,
            version: version
        )
    }

    private static func approvedRoot(forExecutableDirectory directory: URL, homeDirectory: URL) -> URL {
        let path = directory.path
        let localRoot = homeDirectory.appendingPathComponent(".local", isDirectory: true).standardizedFileURL
        if isDescendant(directory, of: localRoot) { return localRoot }
        if path == "/usr/bin" || path == "/bin" { return URL(fileURLWithPath: "/usr", isDirectory: true) }
        return directory
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericVersionComponents(lhs)
        let right = numericVersionComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericVersionComponents(_ value: String) -> [Int] {
        value.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }
}

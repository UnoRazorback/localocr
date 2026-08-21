import Darwin
import Foundation

public struct StudioBatchPlan: Sendable, Equatable {
    public let outputRoot: URL
    public let items: [StudioBatchItem]
    public let skipped: [StudioBatchSkippedInput]
    public let duplicateCount: Int

    public init(
        outputRoot: URL,
        items: [StudioBatchItem],
        skipped: [StudioBatchSkippedInput],
        duplicateCount: Int
    ) {
        self.outputRoot = outputRoot
        self.items = items
        self.skipped = skipped
        self.duplicateCount = duplicateCount
    }
}

public enum StudioBatchPlanningError: Error, Sendable, Equatable {
    case unsafeOutputRoot
    case escapedOutputRoot
    case missingActivePlan
}

public protocol StudioBatchOutputPlanning: Sendable {
    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation
}

public actor BatchOutputPlanner: StudioBatchOutputPlanning {
    private let fileManager: FileManager
    private let caseSensitivityResolver: any DestinationCaseSensitivityResolving
    /// Plans are replaced atomically after successful planning so refresh can retain peer reservations.
    private var activePlans: [PhysicalOutputRootIdentity: ActivePlanClaims] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        caseSensitivityResolver = VolumeCaseSensitivityResolver()
    }

    init(
        fileManager: FileManager = .default,
        caseSensitivityResolver: any DestinationCaseSensitivityResolving
    ) {
        self.fileManager = fileManager
        self.caseSensitivityResolver = caseSensitivityResolver
    }

    public func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        let physicalOutputRoot = try validatedOutputRoot(outputRoot)
        let destinationSemantics = DestinationPathSemantics(
            outputRoot: physicalOutputRoot,
            resolver: caseSensitivityResolver
        )
        let outputRootIdentity = PhysicalOutputRootIdentity(physicalOutputRoot)
        let folderRoots = discovery.selectedFolderRoots.map(physicalURLResolvingExistingAncestors)

        guard folderRoots.allSatisfy({ !isEqualOrDescendant(physicalOutputRoot, of: $0) }) else {
            throw StudioBatchPlanningError.unsafeOutputRoot
        }

        var claims = PathClaims()
        let groups = try allocatedGroups(
            for: discovery.candidates,
            folderRoots: folderRoots,
            outputRoot: physicalOutputRoot,
            semantics: destinationSemantics,
            claims: &claims
        )
        var directories: [UUID: URL] = [:]
        for candidate in discovery.candidates {
            let directory = try outputDirectory(
                for: candidate,
                folderRoots: folderRoots,
                groups: groups,
                outputRoot: physicalOutputRoot
            )
            try reserveRequiredDirectories(
                through: directory,
                beneath: physicalOutputRoot,
                semantics: destinationSemantics,
                claims: &claims
            )
            directories[candidate.id] = directory
        }

        var items: [StudioBatchItem] = []
        var finalClaimsByItemID: [UUID: DestinationPathKey] = [:]

        for candidate in discovery.candidates {
            guard let directory = directories[candidate.id] else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }
            let reservation = try reserve(
                for: candidate,
                in: directory,
                outputRoot: physicalOutputRoot,
                semantics: destinationSemantics,
                claims: &claims
            )
            finalClaimsByItemID[candidate.id] = destinationSemantics.key(for: reservation.finalURL)
            items.append(
                StudioBatchItem(
                    id: candidate.id,
                    candidate: candidate,
                    reservation: reservation,
                    state: .queued
                )
            )
        }

        let plan = StudioBatchPlan(
            outputRoot: physicalOutputRoot,
            items: items,
            skipped: discovery.skipped,
            duplicateCount: discovery.duplicateCount
        )
        activePlans[outputRootIdentity] = ActivePlanClaims(
            outputRoot: physicalOutputRoot,
            outputRootIdentity: outputRootIdentity,
            semantics: destinationSemantics,
            claims: claims,
            finalClaimsByItemID: finalClaimsByItemID
        )
        return plan
    }

    public func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation {
        let physicalOutputRoot = try validatedOutputRoot(outputRoot)
        let outputRootIdentity = PhysicalOutputRootIdentity(physicalOutputRoot)
        guard item.reservation.outputRoot == physicalOutputRoot else {
            throw StudioBatchPlanningError.unsafeOutputRoot
        }

        _ = try relativeComponents(for: item.candidate.relativePath)
        let reservedFinalURL = item.reservation.finalURL.standardizedFileURL
        let directory = physicalURLResolvingExistingAncestors(reservedFinalURL.deletingLastPathComponent())
        guard isEqualOrDescendant(directory, of: physicalOutputRoot) else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        if !pathEntryExists(reservedFinalURL) {
            let finalURL = physicalURLResolvingExistingAncestors(reservedFinalURL)
            guard isStrictDescendant(finalURL, of: physicalOutputRoot) else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }
        }

        guard var activePlan = activePlans[outputRootIdentity],
              activePlan.outputRoot == physicalOutputRoot,
              activePlan.outputRootIdentity == outputRootIdentity
        else {
            throw StudioBatchPlanningError.missingActivePlan
        }
        let destinationSemantics = activePlan.semantics
        if let previousFinalClaim = activePlan.finalClaimsByItemID[item.id] {
            activePlan.claims.removeFinal(previousFinalClaim)
        }
        try reserveRequiredDirectories(
            through: directory,
            beneath: physicalOutputRoot,
            semantics: destinationSemantics,
            claims: &activePlan.claims
        )
        let reservation = try reserve(
            for: item.candidate,
            in: directory,
            outputRoot: physicalOutputRoot,
            semantics: destinationSemantics,
            claims: &activePlan.claims
        )
        activePlan.finalClaimsByItemID[item.id] = destinationSemantics.key(for: reservation.finalURL)
        activePlans[outputRootIdentity] = activePlan
        return reservation
    }

    private func validatedOutputRoot(_ outputRoot: URL) throws -> URL {
        let standardizedRoot = outputRoot.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardizedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(standardizedRoot)
        else {
            throw StudioBatchPlanningError.unsafeOutputRoot
        }

        let physicalRoot = physicalURLResolvingExistingAncestors(standardizedRoot)
        var physicalIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: physicalRoot.path, isDirectory: &physicalIsDirectory),
              physicalIsDirectory.boolValue,
              !isSymbolicLink(physicalRoot)
        else {
            throw StudioBatchPlanningError.unsafeOutputRoot
        }
        return physicalRoot
    }

    private func allocatedGroups(
        for candidates: [StudioBatchCandidate],
        folderRoots: [URL],
        outputRoot: URL,
        semantics: DestinationPathSemantics,
        claims: inout PathClaims
    ) throws -> [URL: URL] {
        var groups: [URL: URL] = [:]

        for candidate in candidates where candidate.outputGroupName != nil {
            let folderRoot = try folderRoot(for: candidate, among: folderRoots)
            guard groups[folderRoot] == nil else { continue }
            let groupName = try groupComponent(named: candidate.outputGroupName!)
            groups[folderRoot] = try allocateGroupDirectory(
                named: groupName,
                outputRoot: outputRoot,
                semantics: semantics,
                claims: &claims
            )
        }
        return groups
    }

    private func outputDirectory(
        for candidate: StudioBatchCandidate,
        folderRoots: [URL],
        groups: [URL: URL],
        outputRoot: URL
    ) throws -> URL {
        let components = try relativeComponents(for: candidate.relativePath)
        var directory = outputRoot

        if candidate.outputGroupName != nil {
            let folderRoot = try folderRoot(for: candidate, among: folderRoots)
            guard let groupDirectory = groups[folderRoot] else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }
            directory = groupDirectory
        }

        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
        }
        let physicalDirectory = physicalURLResolvingExistingAncestors(directory)
        guard isEqualOrDescendant(physicalDirectory, of: outputRoot) else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        return physicalDirectory
    }

    private func reserveRequiredDirectories(
        through directory: URL,
        beneath outputRoot: URL,
        semantics: DestinationPathSemantics,
        claims: inout PathClaims
    ) throws {
        guard isEqualOrDescendant(directory, of: outputRoot) else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        guard isStrictDescendant(directory, of: outputRoot) else { return }
        guard let components = relativeComponents(of: directory, beneath: outputRoot) else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }

        var claimedDirectory = outputRoot
        for component in components {
            claimedDirectory.appendPathComponent(component, isDirectory: true)
            guard claims.reserveDirectory(semantics.key(for: claimedDirectory)) else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }
        }
    }

    private func reserve(
        for candidate: StudioBatchCandidate,
        in directory: URL,
        outputRoot: URL,
        semantics: DestinationPathSemantics,
        claims: inout PathClaims
    ) throws -> StudioBatchReservation {
        let name = try outputName(for: candidate)
        var suffix = 1

        while true {
            let filename = suffix == 1
                ? "\(name.stem).\(name.extension)"
                : "\(name.stem)_\(suffix).\(name.extension)"
            let candidateURL = directory
                .appendingPathComponent(filename, isDirectory: false)
                .standardizedFileURL
            if pathEntryExists(candidateURL) {
                suffix += 1
                continue
            }
            let physicalCandidateURL = physicalURLResolvingExistingAncestors(candidateURL)
            guard isStrictDescendant(physicalCandidateURL, of: outputRoot) else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }

            if claims.reserveFinal(semantics.key(for: physicalCandidateURL)) {
                return StudioBatchReservation(finalURL: physicalCandidateURL, outputRoot: outputRoot)
            }
            suffix += 1
        }
    }

    private func allocateGroupDirectory(
        named name: String,
        outputRoot: URL,
        semantics: DestinationPathSemantics,
        claims: inout PathClaims
    ) throws -> URL {
        var suffix = 1

        while true {
            let dirname = suffix == 1 ? name : "\(name)_\(suffix)"
            let candidateURL = outputRoot
                .appendingPathComponent(dirname, isDirectory: true)
                .standardizedFileURL
            if pathEntryExists(candidateURL) {
                suffix += 1
                continue
            }
            let physicalCandidateURL = physicalURLResolvingExistingAncestors(candidateURL)
            guard isStrictDescendant(physicalCandidateURL, of: outputRoot) else {
                throw StudioBatchPlanningError.escapedOutputRoot
            }

            let claimKey = semantics.key(for: physicalCandidateURL)
            if !claims.isClaimed(claimKey), claims.reserveDirectory(claimKey) {
                return physicalCandidateURL
            }
            suffix += 1
        }
    }

    private func folderRoot(
        for candidate: StudioBatchCandidate,
        among folderRoots: [URL]
    ) throws -> URL {
        let components = try relativeComponents(for: candidate.relativePath)
        guard let groupName = candidate.outputGroupName else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        _ = try groupComponent(named: groupName)
        let sourceURL = physicalURLResolvingExistingAncestors(candidate.standardizedSourceURL)
        let matches = folderRoots.filter { folderRoot in
            folderRoot.lastPathComponent == groupName &&
                relativeComponents(of: sourceURL, beneath: folderRoot) == components
        }

        guard matches.count == 1, let folderRoot = matches.first else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        return folderRoot
    }

    private func outputName(for candidate: StudioBatchCandidate) throws -> (stem: String, extension: String) {
        let components = try relativeComponents(for: candidate.relativePath)
        guard let sourceFilename = components.last else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        let stem = URL(fileURLWithPath: sourceFilename).deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem != ".", stem != ".." else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }

        switch candidate.kind {
        case .pdf:
            return ("\(stem)_searchable", "pdf")
        case .image:
            return (stem, "txt")
        }
    }

    private func groupComponent(named name: String) throws -> String {
        let components = try relativeComponents(for: name)
        guard components.count == 1, let component = components.first else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        return component
    }

    private func relativeComponents(for path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw StudioBatchPlanningError.escapedOutputRoot
        }
        return components
    }

    private func physicalURLResolvingExistingAncestors(_ url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while !pathEntryExists(existingAncestor) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }

        var resolvedURL = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            resolvedURL.appendPathComponent(component, isDirectory: false)
        }
        return resolvedURL.standardizedFileURL
    }

    private func relativeComponents(of url: URL, beneath root: URL) -> [String]? {
        guard isStrictDescendant(url, of: root) else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return String(url.path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
    }

    private func isEqualOrDescendant(_ url: URL, of root: URL) -> Bool {
        url.path == root.path || isStrictDescendant(url, of: root)
    }

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0
    }
}

protocol DestinationCaseSensitivityResolving: Sendable {
    func caseSensitive(for outputRoot: URL) throws -> Bool?
}

private struct VolumeCaseSensitivityResolver: DestinationCaseSensitivityResolving {
    func caseSensitive(for outputRoot: URL) throws -> Bool? {
        let values = try outputRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values.volumeSupportsCaseSensitiveNames
    }
}

private struct DestinationPathSemantics: Sendable {
    let caseSensitive: Bool

    init(outputRoot: URL, resolver: any DestinationCaseSensitivityResolving) {
        caseSensitive = (try? resolver.caseSensitive(for: outputRoot)) ?? false
    }

    func key(for url: URL) -> DestinationPathKey {
        DestinationPathKey(
            components: url.standardizedFileURL.pathComponents.map { component in
                let normalized = component.precomposedStringWithCanonicalMapping
                return caseSensitive
                    ? normalized
                    : normalized.folding(options: .caseInsensitive, locale: nil)
            }
        )
    }
}

private struct DestinationPathKey: Hashable, Sendable {
    let components: [String]

    func conflicts(with other: DestinationPathKey) -> Bool {
        let commonCount = min(components.count, other.components.count)
        return components.prefix(commonCount).elementsEqual(other.components.prefix(commonCount))
    }

    func isEqualToOrAncestor(of other: DestinationPathKey) -> Bool {
        guard components.count <= other.components.count else { return false }
        return components.elementsEqual(other.components.prefix(components.count))
    }
}

private struct PhysicalOutputRootIdentity: Hashable, Sendable {
    let outputRoot: URL

    init(_ outputRoot: URL) {
        self.outputRoot = outputRoot.standardizedFileURL
    }
}

private enum PathClaim: Sendable {
    case directory
    case final
}

private struct PathClaims: Sendable {
    private var claims: [DestinationPathKey: PathClaim] = [:]

    func isClaimed(_ key: DestinationPathKey) -> Bool {
        claims[key] != nil
    }

    mutating func reserveDirectory(_ key: DestinationPathKey) -> Bool {
        if let existing = claims[key] {
            return existing == .directory
        }
        guard !claims.contains(where: { claim in
            claim.value == .final && key.conflicts(with: claim.key)
        }) else {
            return false
        }
        claims[key] = .directory
        return true
    }

    mutating func reserveFinal(_ key: DestinationPathKey) -> Bool {
        guard !claims.contains(where: { claim in
            switch claim.value {
            case .directory:
                key.isEqualToOrAncestor(of: claim.key)
            case .final:
                key.conflicts(with: claim.key)
            }
        }) else {
            return false
        }
        claims[key] = .final
        return true
    }

    mutating func removeFinal(_ key: DestinationPathKey) {
        if claims[key] == .final {
            claims.removeValue(forKey: key)
        }
    }
}

private struct ActivePlanClaims: Sendable {
    let outputRoot: URL
    let outputRootIdentity: PhysicalOutputRootIdentity
    let semantics: DestinationPathSemantics
    var claims: PathClaims
    var finalClaimsByItemID: [UUID: DestinationPathKey]

    init(
        outputRoot: URL,
        outputRootIdentity: PhysicalOutputRootIdentity,
        semantics: DestinationPathSemantics,
        claims: PathClaims = .init(),
        finalClaimsByItemID: [UUID: DestinationPathKey] = [:]
    ) {
        self.outputRoot = outputRoot
        self.outputRootIdentity = outputRootIdentity
        self.semantics = semantics
        self.claims = claims
        self.finalClaimsByItemID = finalClaimsByItemID
    }
}

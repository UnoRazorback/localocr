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

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        let physicalOutputRoot = try validatedOutputRoot(outputRoot)
        let folderRoots = discovery.selectedFolderRoots.map(physicalURLResolvingExistingAncestors)

        guard folderRoots.allSatisfy({ !isEqualOrDescendant(physicalOutputRoot, of: $0) }) else {
            throw StudioBatchPlanningError.unsafeOutputRoot
        }

        let groups = try allocatedGroups(
            for: discovery.candidates,
            folderRoots: folderRoots,
            outputRoot: physicalOutputRoot
        )
        var reservedFinalURLs = Set<URL>()
        var items: [StudioBatchItem] = []

        for candidate in discovery.candidates {
            let directory = try outputDirectory(
                for: candidate,
                folderRoots: folderRoots,
                groups: groups,
                outputRoot: physicalOutputRoot
            )
            let reservation = try reserve(
                for: candidate,
                in: directory,
                outputRoot: physicalOutputRoot,
                reservedFinalURLs: &reservedFinalURLs
            )
            items.append(
                StudioBatchItem(
                    id: candidate.id,
                    candidate: candidate,
                    reservation: reservation,
                    state: .queued
                )
            )
        }

        return StudioBatchPlan(
            outputRoot: physicalOutputRoot,
            items: items,
            skipped: discovery.skipped,
            duplicateCount: discovery.duplicateCount
        )
    }

    public func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation {
        let physicalOutputRoot = try validatedOutputRoot(outputRoot)
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

        var reservedFinalURLs = Set<URL>()
        return try reserve(
            for: item.candidate,
            in: directory,
            outputRoot: physicalOutputRoot,
            reservedFinalURLs: &reservedFinalURLs
        )
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
        outputRoot: URL
    ) throws -> [URL: URL] {
        var groups: [URL: URL] = [:]
        var allocatedGroupURLs = Set<URL>()

        for candidate in candidates where candidate.outputGroupName != nil {
            let folderRoot = try folderRoot(for: candidate, among: folderRoots)
            guard groups[folderRoot] == nil else { continue }
            let groupName = try groupComponent(named: candidate.outputGroupName!)
            groups[folderRoot] = try allocateGroupDirectory(
                named: groupName,
                outputRoot: outputRoot,
                allocatedGroupURLs: &allocatedGroupURLs
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

    private func reserve(
        for candidate: StudioBatchCandidate,
        in directory: URL,
        outputRoot: URL,
        reservedFinalURLs: inout Set<URL>
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

            if !reservedFinalURLs.contains(physicalCandidateURL) {
                reservedFinalURLs.insert(physicalCandidateURL)
                return StudioBatchReservation(finalURL: physicalCandidateURL, outputRoot: outputRoot)
            }
            suffix += 1
        }
    }

    private func allocateGroupDirectory(
        named name: String,
        outputRoot: URL,
        allocatedGroupURLs: inout Set<URL>
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

            if !allocatedGroupURLs.contains(physicalCandidateURL) {
                allocatedGroupURLs.insert(physicalCandidateURL)
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

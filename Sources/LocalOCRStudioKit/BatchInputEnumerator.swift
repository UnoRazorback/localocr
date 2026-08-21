import Foundation
import UniformTypeIdentifiers

public protocol StudioBatchInputEnumerating: Sendable {
    func discover(selections: [URL]) async -> StudioBatchDiscovery
}

public actor BatchInputEnumerator: StudioBatchInputEnumerating {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(selections: [URL]) async -> StudioBatchDiscovery {
        var state = DiscoveryState()

        for selection in selections {
            inspectSelection(selection, state: &state)
        }

        return StudioBatchDiscovery(
            candidates: state.candidates.sorted(by: { standardizedPath($0.sourceURL) < standardizedPath($1.sourceURL) }),
            skipped: state.skipped.sorted(by: { standardizedPath($0.sourceURL) < standardizedPath($1.sourceURL) }),
            duplicateCount: state.duplicateCount,
            selectedFolderRoots: state.selectedFolderRoots.sorted(by: { standardizedPath($0) < standardizedPath($1) })
        )
    }

    private func inspectSelection(_ selection: URL, state: inout DiscoveryState) {
        let sourceURL = selection.standardizedFileURL

        guard let properties = properties(for: sourceURL, state: &state) else {
            return
        }

        if properties.isSymbolicLink == true {
            appendSkipped(sourceURL, title: "Symbolic Link Skipped", message: "Symbolic links are not processed.", state: &state)
            return
        }
        if properties.isPackage == true {
            appendSkipped(sourceURL, title: "Package Skipped", message: "Application and document packages are not processed.", state: &state)
            return
        }
        if properties.isHidden == true {
            appendSkipped(sourceURL, title: "Hidden Item Skipped", message: "Hidden files and folders are not processed.", state: &state)
            return
        }

        if properties.isDirectory == true {
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                appendUnavailable(sourceURL, state: &state)
                return
            }

            let identity = resolvedIdentity(for: sourceURL)
            if state.selectedFolderRootIdentities.insert(identity).inserted {
                state.selectedFolderRoots.append(sourceURL)
            }
            inspectDirectoryContents(of: sourceURL, folderRoot: sourceURL, state: &state)
            return
        }

        inspectFile(sourceURL, properties: properties, folderRoot: nil, state: &state)
    }

    private func inspectDirectoryContents(of directory: URL, folderRoot: URL, state: inout DiscoveryState) {
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
            for child in children.sorted(by: { standardizedPath($0) < standardizedPath($1) }) {
                inspectDescendant(child, folderRoot: folderRoot, state: &state)
            }
        } catch {
            appendUnavailable(directory, state: &state)
        }
    }

    private func inspectDescendant(_ url: URL, folderRoot: URL, state: inout DiscoveryState) {
        let sourceURL = url.standardizedFileURL

        guard let properties = properties(for: sourceURL, state: &state) else {
            return
        }

        if properties.isSymbolicLink == true {
            appendSkipped(sourceURL, title: "Symbolic Link Skipped", message: "Symbolic links are not processed.", state: &state)
            return
        }
        if properties.isPackage == true {
            appendSkipped(sourceURL, title: "Package Skipped", message: "Application and document packages are not processed.", state: &state)
            return
        }
        if properties.isHidden == true {
            appendSkipped(sourceURL, title: "Hidden Item Skipped", message: "Hidden files and folders are not processed.", state: &state)
            return
        }

        if properties.isDirectory == true {
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                appendUnavailable(sourceURL, state: &state)
                return
            }
            inspectDirectoryContents(of: sourceURL, folderRoot: folderRoot, state: &state)
            return
        }

        inspectFile(sourceURL, properties: properties, folderRoot: folderRoot, state: &state)
    }

    private func inspectFile(
        _ sourceURL: URL,
        properties: URLResourceValues,
        folderRoot: URL?,
        state: inout DiscoveryState
    ) {
        guard properties.isRegularFile == true else {
            appendSkipped(sourceURL, title: "Unsupported File", message: "Only PDF and image files can be processed.", state: &state)
            return
        }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            appendUnavailable(sourceURL, state: &state)
            return
        }
        guard let kind = documentKind(for: sourceURL) else {
            appendSkipped(sourceURL, title: "Unsupported File", message: "Only PDF and image files can be processed.", state: &state)
            return
        }

        let identity = resolvedIdentity(for: sourceURL)
        guard state.candidateIdentities.insert(identity).inserted else {
            state.duplicateCount += 1
            return
        }

        state.candidates.append(
            StudioBatchCandidate(
                id: UUID(),
                sourceURL: sourceURL,
                standardizedSourceURL: identity,
                kind: kind,
                relativePath: folderRoot.map { relativePath(of: sourceURL, from: $0) } ?? sourceURL.lastPathComponent,
                outputGroupName: folderRoot?.lastPathComponent
            )
        )
    }

    private func properties(for sourceURL: URL, state: inout DiscoveryState) -> URLResourceValues? {
        do {
            return try sourceURL.resourceValues(forKeys: Set(resourceKeys))
        } catch {
            appendUnavailable(sourceURL, state: &state)
            return nil
        }
    }

    private func documentKind(for sourceURL: URL) -> StudioDocumentKind? {
        if sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame {
            return .pdf
        }
        if UTType(filenameExtension: sourceURL.pathExtension)?.conforms(to: .image) == true {
            return .image
        }
        return nil
    }

    private func resolvedIdentity(for sourceURL: URL) -> URL {
        sourceURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func relativePath(of sourceURL: URL, from folderRoot: URL) -> String {
        let rootPath = folderRoot.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard sourcePath.hasPrefix(prefix) else {
            return sourceURL.lastPathComponent
        }
        return String(sourcePath.dropFirst(prefix.count))
    }

    private func appendUnavailable(_ sourceURL: URL, state: inout DiscoveryState) {
        appendSkipped(sourceURL, title: "File Unavailable", message: "This file is unavailable or cannot be read.", state: &state)
    }

    private func appendSkipped(_ sourceURL: URL, title: String, message: String, state: inout DiscoveryState) {
        state.skipped.append(
            StudioBatchSkippedInput(
                id: UUID(),
                sourceURL: sourceURL,
                reason: StudioBatchIssue(title: title, message: message, details: nil)
            )
        )
    }
}

private let resourceKeys: [URLResourceKey] = [
    .isRegularFileKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .isPackageKey,
    .isHiddenKey,
]

private func standardizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path
}

private struct DiscoveryState {
    var candidates: [StudioBatchCandidate] = []
    var skipped: [StudioBatchSkippedInput] = []
    var duplicateCount = 0
    var candidateIdentities: Set<URL> = []
    var selectedFolderRoots: [URL] = []
    var selectedFolderRootIdentities: Set<URL> = []
}

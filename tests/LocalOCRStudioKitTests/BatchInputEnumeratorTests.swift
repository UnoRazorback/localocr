import Foundation
@testable import LocalOCRStudioKit
import Testing

@Suite struct BatchInputEnumeratorTests {
    @Test func discoversDirectPDFAndImageSelections() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "photo.jpg")
        let pdf = root.appending(path: "invoice.PDF")
        try Data().write(to: image)
        try Data().write(to: pdf)

        let discovery = await BatchInputEnumerator().discover(selections: [image, pdf])

        #expect(discovery.candidates.map(\.relativePath) == ["invoice.PDF", "photo.jpg"])
        #expect(discovery.candidates.map(\.kind) == [.pdf, .image])
        #expect(discovery.candidates.allSatisfy { $0.outputGroupName == nil })
        #expect(discovery.skipped.isEmpty)
    }

    @Test func recursiveDiscoveryUsesRelativePathsAndRefusesLinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: "invoice.pdf"))
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: false)
        try Data().write(to: root.appending(path: "nested/photo.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.pdf"),
            withDestinationURL: root.appending(path: "invoice.pdf")
        )

        let discovery = await BatchInputEnumerator().discover(selections: [root])

        #expect(discovery.candidates.map(\.relativePath) == ["invoice.pdf", "nested/photo.png"])
        #expect(discovery.candidates.allSatisfy { $0.outputGroupName == root.lastPathComponent })
        #expect(discovery.skipped.contains {
            $0.sourceURL.lastPathComponent == "linked.pdf" && $0.reason.title == "Symbolic Link Skipped"
        })
    }

    @Test func deduplicatesDirectAndFolderReachableFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appending(path: "invoice.pdf")
        try Data().write(to: pdf)

        let discovery = await BatchInputEnumerator().discover(selections: [pdf, root, pdf])

        #expect(discovery.candidates.count == 1)
        #expect(discovery.candidates[0].relativePath == "invoice.pdf")
        #expect(discovery.candidates[0].outputGroupName == nil)
        #expect(discovery.duplicateCount == 2)
    }

    @Test func directSelectionMetadataOverridesEarlierFolderDiscovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appending(path: "invoice.pdf")
        try Data().write(to: pdf)

        let discovery = await BatchInputEnumerator().discover(selections: [root, pdf])

        #expect(discovery.candidates.count == 1)
        #expect(discovery.candidates[0].relativePath == "invoice.pdf")
        #expect(discovery.candidates[0].outputGroupName == nil)
        #expect(discovery.duplicateCount == 1)
    }

    @Test func skipsHiddenEntriesAndPackagesWithoutDescendingIntoThem() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: ".hidden.pdf"))
        let package = root.appending(path: "Preview.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data().write(to: package.appending(path: "inside.pdf"))
        try Data().write(to: root.appending(path: "visible.pdf"))

        let discovery = await BatchInputEnumerator().discover(selections: [root])

        #expect(discovery.candidates.map(\.relativePath) == ["visible.pdf"])
        #expect(discovery.skipped.contains { $0.sourceURL.lastPathComponent == ".hidden.pdf" && $0.reason.title == "Hidden Item Skipped" })
        #expect(discovery.skipped.contains { $0.sourceURL.lastPathComponent == "Preview.app" && $0.reason.title == "Package Skipped" })
        #expect(!discovery.skipped.contains { $0.sourceURL.lastPathComponent == "inside.pdf" })
    }

    @Test func skipsDirectSymlinksUnsupportedAndUnavailableFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appending(path: "invoice.pdf")
        let directLink = root.appending(path: "direct-link.pdf")
        let unsupported = root.appending(path: "notes.txt")
        let unavailable = root.appending(path: "missing.pdf")
        try Data().write(to: pdf)
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: pdf)
        try Data().write(to: unsupported)

        let discovery = await BatchInputEnumerator().discover(selections: [unavailable, unsupported, directLink])

        #expect(discovery.candidates.isEmpty)
        #expect(discovery.skipped.map(\.reason.title) == ["Symbolic Link Skipped", "File Unavailable", "Unsupported File"])
        #expect(discovery.skipped.map { $0.sourceURL.lastPathComponent } == ["direct-link.pdf", "missing.pdf", "notes.txt"])
    }

    @Test func skipsUnreadableSupportedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unreadable = root.appending(path: "private.pdf")
        try Data().write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        let discovery = await BatchInputEnumerator().discover(selections: [unreadable])

        #expect(discovery.candidates.isEmpty)
        #expect(discovery.skipped.map(\.reason.title) == ["File Unavailable"])
    }

    @Test func outputIsSortedRegardlessOfSelectionOrder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let zeta = folder.appending(path: "zeta.pdf")
        let alpha = root.appending(path: "alpha.pdf")
        let unsupported = root.appending(path: "middle.txt")
        try Data().write(to: zeta)
        try Data().write(to: alpha)
        try Data().write(to: unsupported)

        let discovery = await BatchInputEnumerator().discover(selections: [zeta, unsupported, folder, alpha])

        #expect(discovery.candidates.map { $0.sourceURL.path } == [alpha.path, zeta.path])
        #expect(discovery.skipped.map { $0.sourceURL.path } == [unsupported.path])
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchInputEnumeratorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

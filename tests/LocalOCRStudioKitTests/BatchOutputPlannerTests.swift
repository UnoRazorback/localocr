import Foundation
@testable import LocalOCRStudioKit
import Testing

@Suite struct BatchOutputPlannerTests {
    @Test func directPDFAndImageOutputsUseTheOutputRootAndExpectedNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pdf = input.appending(path: "scan.PDF")
        let image = input.appending(path: "photo.jpg")
        try writeEmptyFile(at: pdf)
        try writeEmptyFile(at: image)

        let discovery = await BatchInputEnumerator().discover(selections: [pdf, image])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "photo.txt").path,
            output.appending(path: "scan_searchable.pdf").path,
        ])
        #expect(plan.items.allSatisfy { $0.reservation.outputRoot == output.standardizedFileURL })
    }

    @Test func folderSelectionsPreserveInternalRelativeStructureWithoutCreatingDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "Receipts", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let pdf = input.appending(path: "2026/April/invoice.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [input])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "Receipts/2026/April/invoice_searchable.pdf").path,
        ])
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: "Receipts").path))
    }

    @Test func duplicateSelectedFolderNamesReceiveDistinctNumberedTopLevelGroups() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "one/Receipts", directoryHint: .isDirectory)
        let second = root.appending(path: "two/Receipts", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first.appending(path: "invoice.pdf"))
        try writeEmptyFile(at: second.appending(path: "invoice.pdf"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "Receipts/invoice_searchable.pdf").path,
            output.appending(path: "Receipts_2/invoice_searchable.pdf").path,
        ])
    }

    @Test func existingTopLevelGroupUsesTheFirstFreeNumberedGroupName() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "Receipts", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: input.appending(path: "invoice.pdf"))
        try FileManager.default.createDirectory(at: output.appending(path: "Receipts"), withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [input])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "Receipts_2/invoice_searchable.pdf").path,
        ])
    }

    @Test func existingOutputsReceiveTheFirstFreeNumberedName() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let pdf = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data().write(to: output.appending(path: "scan_searchable.pdf"))
        try Data().write(to: output.appending(path: "scan_searchable_2.pdf"))

        let discovery = await BatchInputEnumerator().discover(selections: [pdf])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items[0].reservation.finalURL.lastPathComponent == "scan_searchable_3.pdf")
    }

    @Test func anExistingSymbolicLinkOutputNameIsTreatedAsOccupied() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let pdf = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appending(path: "other.pdf"))
        try FileManager.default.createSymbolicLink(
            at: output.appending(path: "scan_searchable.pdf"),
            withDestinationURL: outside.appending(path: "other.pdf")
        )

        let discovery = await BatchInputEnumerator().discover(selections: [pdf])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items[0].reservation.finalURL == output.appending(path: "scan_searchable_2.pdf"))
    }

    @Test func plannedDirectNameCollisionsReceiveNumberedReservations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first/photo.jpg")
        let second = root.appending(path: "second/photo.png")
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first)
        try writeEmptyFile(at: second)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "photo.txt").path,
            output.appending(path: "photo_2.txt").path,
        ])
    }

    @Test func folderGroupDirectoryForcesAConflictingDirectFinalToNumber() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "sources/photo.txt", directoryHint: .isDirectory)
        let directImage = root.appending(path: "sources/z/photo.jpg")
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: folder.appending(path: "scan.pdf"))
        try writeEmptyFile(at: directImage)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [folder, directImage])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "photo.txt/scan_searchable.pdf").path,
            output.appending(path: "photo_2.txt").path,
        ])
    }

    @Test func requiredNestedDirectoryForcesAConflictingFolderFinalToNumber() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Batch", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: folder.appending(path: "photo.jpg"))
        try writeEmptyFile(at: folder.appending(path: "photo.txt/scan.pdf"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [folder])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "Batch/photo_2.txt").path,
            output.appending(path: "Batch/photo.txt/scan_searchable.pdf").path,
        ])
    }

    @Test func directCaseAliasesUseDistinctReservationsWhenTheDestinationIgnoresCase() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "sources/one/Photo.jpg")
        let second = root.appending(path: "sources/two/photo.png")
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first)
        try writeEmptyFile(at: second)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let aliasesCollide = try destinationTreatsAliasesAsTheSameEntry(
            in: output,
            firstName: "CaseProbe",
            secondName: "caseprobe"
        )

        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.lastPathComponent } == [
            "Photo.txt",
            aliasesCollide ? "photo_2.txt" : "photo.txt",
        ])
    }

    @Test func folderCaseAliasesUseDistinctGroupsWhenTheDestinationIgnoresCase() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "sources/one/Receipts", directoryHint: .isDirectory)
        let second = root.appending(path: "sources/two/receipts", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first.appending(path: "invoice.pdf"))
        try writeEmptyFile(at: second.appending(path: "invoice.pdf"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let aliasesCollide = try destinationTreatsAliasesAsTheSameEntry(
            in: output,
            firstName: "GroupProbe",
            secondName: "groupprobe"
        )

        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.path } == [
            output.appending(path: "Receipts/invoice_searchable.pdf").path,
            output.appending(path: aliasesCollide ? "receipts_2/invoice_searchable.pdf" : "receipts/invoice_searchable.pdf").path,
        ])
    }

    @Test func unicodeEquivalentDirectNamesUseDistinctReservations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "sources/one/Café.jpg")
        let second = root.appending(path: "sources/two/Cafe\u{301}.png")
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first)
        try writeEmptyFile(at: second)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let plan = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.lastPathComponent } == [
            "Café.txt",
            "Cafe\u{301}_2.txt",
        ])
    }

    @Test func rejectsSymbolicLinkFileAndMissingOutputRoots() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let physicalOutput = root.appending(path: "physical-output", directoryHint: .isDirectory)
        let outputLink = root.appending(path: "output-link", directoryHint: .isDirectory)
        let outputFile = root.appending(path: "output-file")
        let missingOutput = root.appending(path: "missing-output", directoryHint: .isDirectory)
        let pdf = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: physicalOutput, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: physicalOutput)
        try Data().write(to: outputFile)
        let discovery = await BatchInputEnumerator().discover(selections: [pdf])

        await assertPlanningError(
            discovery: discovery,
            outputRoot: outputLink,
            expected: .unsafeOutputRoot
        )
        await assertPlanningError(
            discovery: discovery,
            outputRoot: outputFile,
            expected: .unsafeOutputRoot
        )
        await assertPlanningError(
            discovery: discovery,
            outputRoot: missingOutput,
            expected: .unsafeOutputRoot
        )
    }

    @Test func rejectsOutputRootsEqualToOrNestedWithinSelectedFolders() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let nestedOutput = input.appending(path: "nested-output", directoryHint: .isDirectory)
        try writeEmptyFile(at: input.appending(path: "scan.pdf"))
        try FileManager.default.createDirectory(at: nestedOutput, withIntermediateDirectories: true)
        let discovery = await BatchInputEnumerator().discover(selections: [input])

        await assertPlanningError(
            discovery: discovery,
            outputRoot: input,
            expected: .unsafeOutputRoot
        )
        await assertPlanningError(
            discovery: discovery,
            outputRoot: nestedOutput,
            expected: .unsafeOutputRoot
        )
    }

    @Test func rejectsUnsafeRelativeAndGroupPathSegments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let source = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: source)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for relativePath in ["", ".", "..", "nested//scan.pdf", "nested/./scan.pdf", "nested/../scan.pdf"] {
            await assertPlanningError(
                discovery: unsafeDiscovery(source: source, relativePath: relativePath, outputGroupName: nil),
                outputRoot: output,
                expected: .escapedOutputRoot
            )
        }
        await assertPlanningError(
            discovery: unsafeDiscovery(source: source, relativePath: "scan.pdf", outputGroupName: ".."),
            outputRoot: output,
            expected: .escapedOutputRoot
        )
    }

    @Test func rejectsAFinalPathThatResolvesOutsideTheOutputRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let source = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: source)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: output.appending(path: "escape"), withDestinationURL: outside)

        await assertPlanningError(
            discovery: unsafeDiscovery(source: source, relativePath: "escape/scan.pdf", outputGroupName: nil),
            outputRoot: output,
            expected: .escapedOutputRoot
        )
    }

    @Test func refreshesAReservationWhenAnExternalFileOccupiesItsFinalPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let pdf = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let discovery = await BatchInputEnumerator().discover(selections: [pdf])
        let planner = BatchOutputPlanner()
        let plan = try await planner.makePlan(discovery: discovery, outputRoot: output)
        try Data().write(to: plan.items[0].reservation.finalURL)

        let refreshed = try await planner.refreshReservation(for: plan.items[0], outputRoot: output)

        #expect(refreshed.finalURL == output.appending(path: "scan_searchable_2.pdf"))
        #expect(refreshed.outputRoot == output.standardizedFileURL)
    }

    @Test func refreshTreatsAnExternalSymbolicLinkAtTheFinalPathAsOccupied() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let pdf = input.appending(path: "scan.pdf")
        try writeEmptyFile(at: pdf)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appending(path: "other.pdf"))
        let discovery = await BatchInputEnumerator().discover(selections: [pdf])
        let planner = BatchOutputPlanner()
        let plan = try await planner.makePlan(discovery: discovery, outputRoot: output)
        try FileManager.default.createSymbolicLink(
            at: plan.items[0].reservation.finalURL,
            withDestinationURL: outside.appending(path: "other.pdf")
        )

        let refreshed = try await planner.refreshReservation(for: plan.items[0], outputRoot: output)

        #expect(refreshed.finalURL == output.appending(path: "scan_searchable_2.pdf"))
    }

    @Test func refreshAvoidsTheReservationsHeldByOtherItemsInTheActivePlan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "sources/one/scan.pdf")
        let second = root.appending(path: "sources/two/scan.pdf")
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try writeEmptyFile(at: first)
        try writeEmptyFile(at: second)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let discovery = await BatchInputEnumerator().discover(selections: [second, first])
        let planner = BatchOutputPlanner()
        let plan = try await planner.makePlan(discovery: discovery, outputRoot: output)
        try Data().write(to: plan.items[0].reservation.finalURL)

        let refreshed = try await planner.refreshReservation(for: plan.items[0], outputRoot: output)

        #expect(plan.items.map { $0.reservation.finalURL.lastPathComponent } == [
            "scan_searchable.pdf",
            "scan_searchable_2.pdf",
        ])
        #expect(refreshed.finalURL.lastPathComponent == "scan_searchable_3.pdf")
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchOutputPlannerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func writeEmptyFile(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
}

private func destinationTreatsAliasesAsTheSameEntry(
    in directory: URL,
    firstName: String,
    secondName: String
) throws -> Bool {
    let first = directory.appending(path: firstName)
    let second = directory.appending(path: secondName)
    defer { try? FileManager.default.removeItem(at: first) }
    try Data().write(to: first)
    return FileManager.default.fileExists(atPath: second.path)
}

private func unsafeDiscovery(
    source: URL,
    relativePath: String,
    outputGroupName: String?
) -> StudioBatchDiscovery {
    StudioBatchDiscovery(
        candidates: [
            StudioBatchCandidate(
                id: UUID(),
                sourceURL: source,
                standardizedSourceURL: source.standardizedFileURL,
                kind: .pdf,
                relativePath: relativePath,
                outputGroupName: outputGroupName
            ),
        ],
        skipped: [],
        duplicateCount: 0,
        selectedFolderRoots: []
    )
}

private func assertPlanningError(
    discovery: StudioBatchDiscovery,
    outputRoot: URL,
    expected: StudioBatchPlanningError
) async {
    do {
        _ = try await BatchOutputPlanner().makePlan(discovery: discovery, outputRoot: outputRoot)
        #expect(Bool(false), "Expected \(expected)")
    } catch let error as StudioBatchPlanningError {
        #expect(error == expected)
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }
}

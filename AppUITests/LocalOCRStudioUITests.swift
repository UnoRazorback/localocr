import AppKit
import XCTest

final class LocalOCRStudioUITests: XCTestCase {
    private static let resultText = """
    LOCALOCR UI FIXTURE
    Quarterly planning is complete.
    Owner: Ray Consulting
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyStateExposesDropZoneAndOpenAction() {
        let app = launch(state: "empty")

        let dropZone = element("studio.drop-zone", in: app)
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5))
        XCTAssertEqual(dropZone.label, "Document drop zone")
        XCTAssertTrue(app.buttons["studio.open"].exists)
        XCTAssertTrue(app.buttons["studio.new-batch"].exists)
        XCTAssertTrue(app.staticTexts["Processed locally on this Mac."].exists)
    }

    func testBatchNavigationReturnsToTheUnchangedSingleDocumentStart() {
        let app = launch(state: "batchReview")
        let firstRow = element(
            "studio.batch.row.00000000-0000-0000-0000-000000000001",
            in: app
        )

        let workspace = element("studio.batch.workspace", in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.batch.add-files"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.add-folder"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.choose-output"].isEnabled)

        let returnToSingle = app.buttons["studio.batch.return-single"]
        XCTAssertTrue(returnToSingle.waitForExistence(timeout: 5))
        XCTAssertTrue(returnToSingle.isEnabled)
        returnToSingle.click()

        XCTAssertTrue(element("studio.drop-zone", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(workspace.exists)

        let newBatch = app.buttons["studio.new-batch"]
        XCTAssertTrue(newBatch.waitForExistence(timeout: 5))
        newBatch.click()

        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertFalse(firstRow.exists)
        let start = app.buttons["studio.batch.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)
    }

    func testBatchReviewFixtureExposesOrderedQueueAndExplicitStart() {
        let app = launch(state: "batchReview")

        XCTAssertTrue(element("studio.batch.workspace", in: app).waitForExistence(timeout: 5))
        let firstRow = element(
            "studio.batch.row.00000000-0000-0000-0000-000000000001",
            in: app
        )
        let secondRow = element(
            "studio.batch.row.00000000-0000-0000-0000-000000000002",
            in: app
        )
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        XCTAssertLessThan(firstRow.frame.minY, secondRow.frame.minY)
        XCTAssertTrue(app.buttons["studio.batch.add-files"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.add-folder"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.choose-output"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.start"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.copy-diagnostics"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.return-single"].isEnabled)
    }

    func testBatchRowKeepsItsIdentifierWhileWrittenStatusAndProgressUpdate() {
        let app = launch(state: "batchReview")
        let rowID = "studio.batch.row.00000000-0000-0000-0000-000000000001"
        let row = element(rowID, in: app)

        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.identifier, rowID)
        XCTAssertTrue(row.label.contains("Queued"), row.debugDescription)

        let start = app.buttons["studio.batch.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.click()

        let updatedStatus = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                row.label.contains("Processing")
                    && row.label.contains("Recognizing page 1 of 2")
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updatedStatus], timeout: 5), .completed)
        XCTAssertEqual(row.identifier, rowID)
    }

    func testSkippedOnlyBatchIsReviewableAndDiagnosticButCannotStart() {
        let app = launch(state: "batchSkippedOnly")

        XCTAssertTrue(element("studio.batch.workspace", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(
                "studio.batch.row.00000000-0000-0000-0000-000000000003",
                in: app
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Batch summary: 0 supported • 1 skipped"]
                .waitForExistence(timeout: 5)
        )
        let start = app.buttons["studio.batch.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.copy-diagnostics"].isEnabled)
    }

    func testPlanningFailureKeepsReviewVisibleButStartDisabled() {
        let app = launch(state: "batchPlanningFailure")

        XCTAssertTrue(element("studio.batch.workspace", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("studio.batch.action-error", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(
                "studio.batch.row.00000000-0000-0000-0000-000000000001",
                in: app
            ).waitForExistence(timeout: 5)
        )
        let start = app.buttons["studio.batch.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.copy-diagnostics"].isEnabled)
    }

    func testBatchProcessingFixtureMakesCancelTheSafeExit() {
        let app = launch(state: "batchProcessing")

        XCTAssertTrue(element("studio.batch.workspace", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.batch.cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.batch.cancel"].isEnabled)
        XCTAssertTrue(app.buttons["studio.batch.copy-diagnostics"].isEnabled)
        let returnToSingle = app.buttons["studio.batch.return-single"]
        XCTAssertTrue(returnToSingle.waitForExistence(timeout: 5))
        XCTAssertFalse(returnToSingle.isEnabled)
        NSPasteboard.general.clearContents()
        app.buttons["studio.batch.copy-diagnostics"].click()
        let diagnostics = NSPasteboard.general.string(forType: .string) ?? "No diagnostics"
        XCTAssertTrue(diagnostics.contains("State: processing"), diagnostics)
        XCTAssertFalse(diagnostics.contains(Self.resultText), diagnostics)
        XCTAssertTrue(
            app.staticTexts["Status: Processing"].waitForExistence(timeout: 5),
            diagnostics + "\n" + app.debugDescription
        )
    }

    func testBatchCompleteFixtureExposesRecoveryAndCompletionActions() {
        let app = launch(state: "batchComplete")

        XCTAssertTrue(element("studio.batch.workspace", in: app).waitForExistence(timeout: 5))
        let retry = app.buttons["studio.batch.retry-failed"]
        let reveal = app.buttons["studio.batch.reveal-output"]
        let copy = app.buttons["studio.batch.copy-diagnostics"]
        let newBatch = app.buttons["studio.batch.new"]
        let returnToSingle = app.buttons["studio.batch.return-single"]
        for control in [retry, reveal, copy, newBatch, returnToSingle] {
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertTrue(control.isEnabled)
        }
        XCTAssertTrue(
            app.staticTexts["Status: Failed"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }

    func testSingleWindowLaunchAndReopenNeverCreatesASecondDocumentWindow() {
        let app = launch(state: "empty")
        let dropZone = element("studio.drop-zone", in: app)

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(app.windows.element(boundBy: 1).waitForExistence(timeout: 1))
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("w", modifierFlags: .command)
        let windowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.count == 0 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [windowClosed], timeout: 5), .completed)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(app.windows.count, 1)
    }

    func testResultStateExposesReadableTextAndDocumentActions() {
        let app = launch(state: "result")

        let result = element("studio.result-text", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(
            (result.value as? String)?
                .contains("Quarterly planning is complete.") == true,
            result.debugDescription
        )
        XCTAssertTrue(app.buttons["studio.copy"].isEnabled)
        XCTAssertTrue(app.buttons["studio.save-text"].isEnabled)
        XCTAssertTrue(app.buttons["studio.create-searchable"].isEnabled)
        XCTAssertTrue(app.buttons["studio.process-another"].isEnabled)
    }

    func testProcessAnotherDocumentReturnsToTheEmptyDropScreen() {
        let app = launch(state: "result")
        let processAnother = app.buttons["studio.process-another"]
        let result = element("studio.result-text", in: app)

        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(processAnother.waitForExistence(timeout: 5))
        processAnother.click()

        XCTAssertTrue(element("studio.drop-zone", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(result.exists)
    }

    func testSearchablePDFBusyStateDisablesProcessAnotherDocument() {
        let app = launch(state: "resultBusy")
        let processAnother = app.buttons["studio.process-another"]

        XCTAssertTrue(processAnother.waitForExistence(timeout: 5))
        XCTAssertTrue(element("studio.progress", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(processAnother.isEnabled)
    }

    func testCopyUsesTheRealPasteboardAction() {
        let app = launch(state: "result")
        let copy = app.buttons["studio.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))

        NSPasteboard.general.clearContents()
        copy.click()

        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied, Self.resultText)
    }

    func testErrorStateExposesRecoveryAndSafeDetails() {
        let app = launch(state: "error")

        XCTAssertTrue(app.buttons["studio.retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.choose-another"].isEnabled)
        XCTAssertTrue(element("studio.error-details", in: app).exists)
        XCTAssertTrue(app.staticTexts["Couldn’t Process Document"].exists)
    }

    func testSaveTextRequiresStandardOverwriteConfirmation() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalOCRStudioUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let destination = testDirectory.appendingPathComponent("fixture-invoice.txt")
        try Data("existing content".utf8).write(to: destination)

        let app = launch(state: "result")
        let saveText = app.buttons["studio.save-text"]
        XCTAssertTrue(saveText.waitForExistence(timeout: 5))
        saveText.click()

        let savePanel = app.dialogs.firstMatch
        XCTAssertTrue(savePanel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])

        let locationField = app.textFields["PathTextField"]
        XCTAssertTrue(locationField.waitForExistence(timeout: 5))
        locationField.typeKey("a", modifierFlags: .command)
        locationField.typeText(testDirectory.path)
        app.typeKey(.return, modifierFlags: [])

        savePanel.buttons["Save"].click()

        let replace = app.buttons["Replace"].firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing content")
        replace.click()

        let predicate = NSPredicate { _, _ in
            (try? String(contentsOf: destination, encoding: .utf8)) == Self.resultText
        }
        expectation(for: predicate, evaluatedWith: destination)
        waitForExpectations(timeout: 5)
    }

    private func launch(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        let testSession = ProcessInfo.processInfo
            .environment["XCTestSessionIdentifier"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        app.launchEnvironment["LOCALOCR_STUDIO_UI_TEST_SESSION"] = testSession
        app.launchEnvironment["LOCALOCR_STUDIO_UI_STATE"] = state
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSOSPLastRootDirectory", "",
        ]
        app.launch()
        return app
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }
}

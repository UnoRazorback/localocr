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
        XCTAssertTrue(app.staticTexts["Processed locally on this Mac."].exists)
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

        app.activate()
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

import Foundation
import Testing
@testable import LocalOCRCommandKit
import LocalOCRIntelligence
import LocalOCRService

@Test func inspectJSONUsesWireContractAndKeepsStderrEmpty() async {
    let harness = CLIHarness(service: FixtureService(inspect: .fixture))

    let status = await harness.run(["inspect", "/tmp/input.pdf", "--json"])

    #expect(status == 0)
    #expect(harness.stdoutJSON()["fully_searchable"] as? Bool == false)
    #expect(harness.stderr == "")
}

@Test func pageCountJSONUsesWireContract() async {
    let harness = CLIHarness(service: FixtureService())

    let status = await harness.run(["page-count", "/tmp/input.pdf", "--json"])

    #expect(status == 0)
    #expect(harness.stdoutJSON()["pages"] as? Int == 2)
    #expect(harness.stderr == "")
}

@Test func ocrMapsAllPDFOptionsAndPrintsJSONOnlyToStandardOutput() async {
    let service = FixtureService()
    let harness = CLIHarness(service: service)

    let status = await harness.run([
        "ocr", "/tmp/input.pdf", "--pages", "2-4", "--dpi", "300",
        "--force-ocr", "--detail", "--no-cache", "--json"
    ])

    #expect(status == 0)
    #expect(harness.stdoutJSON()["source_sha256"] as? String == "abc")
    #expect(harness.stderr.contains("ocr"))
    let request = await service.recorder.lastOCRRequest()
    #expect(request?.pageRange == "2-4")
    #expect(request?.dpi == 300)
    #expect(request?.forceOCR == true)
    #expect(request?.includeLines == true)
    #expect(request?.usesCache == false)
}

@Test func ocrUsesTheDefaultDPIAndFormatsPagesForPeople() async {
    let service = FixtureService()
    let harness = CLIHarness(service: service)

    let status = await harness.run(["ocr", "/tmp/input.pdf"])

    #expect(status == 0)
    #expect(harness.stdout.contains("--- Page 1 ---"))
    #expect(harness.stdout.contains("Hello"))
    #expect((await service.recorder.lastOCRRequest())?.dpi == 250)
}

@Test func partialOCRReturnsThree() async {
    let response = PDFOCRResponse(
        sourcePath: "/tmp/input.pdf", sourceSHA256: "abc", pages: [],
        failedPages: [2], emptyOCRPages: [], rotatedOCRPages: []
    )
    let harness = CLIHarness(service: FixtureService(ocr: response))

    #expect(await harness.run(["ocr", "/tmp/input.pdf", "--json"]) == 3)
}

@Test func batchMapsSharedPDFOptionsAndReturnsThreeForAnyFailure() async {
    let response = BatchOCRResponse(
        processed: 2, succeeded: 1, failed: 1,
        results: [.success(.fixture), .failure(sourcePath: "/tmp/b.pdf", message: "bad pdf")]
    )
    let service = FixtureService(batch: response)
    let harness = CLIHarness(service: service)

    let status = await harness.run([
        "batch", "/tmp/a.pdf", "/tmp/b.pdf", "--pages", "1", "--dpi", "288",
        "--force-ocr", "--detail", "--no-cache", "--json"
    ])

    #expect(status == 3)
    #expect(harness.stdoutJSON()["failed"] as? Int == 1)
    let request = await service.recorder.lastBatchRequest()
    #expect(request?.fileURLs.map(\.path) == ["/tmp/a.pdf", "/tmp/b.pdf"])
    #expect(request?.pageRange == "1")
    #expect(request?.dpi == 288)
    #expect(request?.forceOCR == true)
    #expect(request?.includeLines == true)
    #expect(request?.usesCache == false)
}

@Test func incompleteBatchIsCancellationAndPreservesItsSingleJSONResponse() async {
    let response = BatchOCRResponse(
        processed: 1, succeeded: 1, failed: 0, results: [.success(.fixture)]
    )
    let harness = CLIHarness(service: FixtureService(batch: response))

    let status = await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf", "--json"])

    #expect(status == 4)
    #expect(harness.stdoutJSON()["processed"] as? Int == 1)
    #expect(harness.stderr.contains("cancelled"))
}

@Test func humanBatchWritesFailuresToStandardErrorAndSuccessfulTextToStandardOutput() async {
    let response = BatchOCRResponse(
        processed: 2, succeeded: 1, failed: 1,
        results: [.success(.fixture), .failure(sourcePath: "/tmp/b.pdf", message: "bad pdf")]
    )
    let harness = CLIHarness(service: FixtureService(batch: response))

    let status = await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf"])

    #expect(status == 3)
    #expect(harness.stdout.contains("--- /tmp/input.pdf ---"))
    #expect(harness.stdout.contains("Hello"))
    #expect(!harness.stdout.contains("/tmp/b.pdf"))
    #expect(harness.stderr.contains("--- /tmp/b.pdf ---"))
    #expect(harness.stderr.contains("bad pdf"))
}

@Test func imageMapsRepeatedLanguagesAndLanguageCorrection() async {
    let service = FixtureService()
    let harness = CLIHarness(service: service)

    let status = await harness.run([
        "image", "/tmp/input.png", "--language", "en-US", "--language", "fr-FR",
        "--no-language-correction", "--json"
    ])

    #expect(status == 0)
    #expect(harness.stdoutJSON()["text"] as? String == "recognized image text")
    let request = await service.recorder.lastImageRequest()
    #expect(request?.recognitionLanguages == ["en-US", "fr-FR"])
    #expect(request?.usesLanguageCorrection == false)
}

@Test func searchableMapsOutputAndReturnsThreeForFailedPages() async {
    let service = FixtureService(searchable: SearchablePDFResponse(outputPath: "/tmp/done.pdf", failedPages: [3]))
    let harness = CLIHarness(service: service)

    let status = await harness.run([
        "searchable", "/tmp/input.pdf", "--output", "/tmp/done.pdf", "--dpi", "250",
        "--force-ocr", "--no-cache", "--json"
    ])

    #expect(status == 3)
    #expect(harness.stdoutJSON()["output_path"] as? String == "/tmp/done.pdf")
    let request = await service.recorder.lastSearchableRequest()
    #expect(request?.outputURL?.path == "/tmp/done.pdf")
    #expect(request?.dpi == 250)
    #expect(request?.forceOCR == true)
    #expect(request?.usesCache == false)
}

@Test func helpIsAvailableForEveryCommand() async {
    for command in ["page-count", "inspect", "ocr", "batch", "image", "searchable", "mcp-consent"] {
        let harness = CLIHarness(service: FixtureService())

        #expect(await harness.run([command, "--help"]) == 0)
        #expect(harness.stdout.contains("Usage: localocr \(command)"))
        #expect(harness.stderr == "")
    }
}

@Test func subcommandHelpWorksAfterAFileArgument() async {
    let harness = CLIHarness(service: FixtureService())

    #expect(await harness.run(["ocr", "/tmp/input.pdf", "--help"]) == 0)
    #expect(harness.stdout.contains("Usage: localocr ocr"))
    #expect(harness.stderr == "")
}

@Test func malformedArgumentsReturnTwoWithoutCallingTheService() async {
    let service = FixtureService()
    let harness = CLIHarness(service: service)

    #expect(await harness.run(["ocr", "/tmp/input.pdf", "--dpi", "601"]) == 2)
    #expect(!(await service.recorder.hasOCRRequests()))
    #expect(harness.stderr.contains("dpi"))
}

@Test func serviceFailuresAndCancellationUseStableExitCodes() async {
    let operationHarness = CLIHarness(service: FixtureService(behavior: .operationFailure))
    let cancellationHarness = CLIHarness(service: FixtureService(behavior: .cancellation))

    #expect(await operationHarness.run(["inspect", "/tmp/input.pdf"]) == 1)
    #expect(await cancellationHarness.run(["inspect", "/tmp/input.pdf"]) == 4)
}

@Test func mcpConsentStatusReportsWhetherConsentIsCurrent() async {
    let requiredIO = FixtureConsentIO(isTerminal: false, answers: [])
    let requiredHarness = CLIHarness(
        service: FixtureService(),
        consentStore: FixtureConsentStore(),
        consentIO: requiredIO
    )
    let receipt = ExternalDataConsentReceipt(
        schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
        policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
        acceptedAt: Date(timeIntervalSinceReferenceDate: 0),
        externalProviderRiskAccepted: true,
        documentToolAccessAccepted: true
    )
    let currentIO = FixtureConsentIO(isTerminal: false, answers: [])
    let currentHarness = CLIHarness(
        service: FixtureService(),
        consentStore: FixtureConsentStore(status: .current(receipt)),
        consentIO: currentIO
    )

    #expect(await requiredHarness.run(["mcp-consent", "status"]) == 2)
    #expect(requiredIO.stdoutText == "required\n")
    #expect(await currentHarness.run(["mcp-consent", "status"]) == 0)
    #expect(currentIO.stdoutText == "current\n")
}

@Test func mcpConsentAcceptFailsClosedOnEmptyOrEOFAtEitherAcknowledgment() async {
    for answers: [String?] in [["", "yes"], ["yes", ""], [], ["yes"]] {
        let store = FixtureConsentStore()
        let io = FixtureConsentIO(isTerminal: true, answers: answers)
        let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

        #expect(await harness.run(["mcp-consent", "accept"]) == 2)
        #expect(await store.acceptanceCount() == 0)
    }
}

@Test func mcpConsentAcceptCancelsWhenEitherAcknowledgmentIsNo() async {
    for answers: [String?] in [["n"], ["yes", "no"]] {
        let store = FixtureConsentStore()
        let io = FixtureConsentIO(isTerminal: true, answers: answers)
        let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

        #expect(await harness.run(["mcp-consent", "accept"]) == 2)
        #expect(await store.acceptanceCount() == 0)
    }
}

@Test func mcpConsentAcceptRejectsAnswersOtherThanYOrYes() async {
    let store = FixtureConsentStore()
    let io = FixtureConsentIO(isTerminal: true, answers: ["Y", "yes "])
    let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

    #expect(await harness.run(["mcp-consent", "accept"]) == 2)
    #expect(await store.acceptanceCount() == 0)
}

@Test func mcpConsentAcceptRecordsConsentOnlyAfterTwoAffirmativeAcknowledgments() async {
    let store = FixtureConsentStore()
    let io = FixtureConsentIO(isTerminal: true, answers: ["Y", "YES"])
    let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

    #expect(await harness.run(["mcp-consent", "accept"]) == 0)
    #expect(await store.acceptanceCount() == 1)
    #expect(io.stdoutText.contains("""
    LocalOCR and Apple Foundation Models process documents locally on this Mac,
    and LocalOCR does not upload them. When you connect LocalOCR to an agent
    through MCP, that MCP client or its AI provider may send filenames, paths,
    document text, summaries, extracted fields, and tool results to an outside
    service. Transmission, retention, model training, and other handling are
    controlled by the agent and provider, not LocalOCR. Review their privacy and
    data policies, and only continue if you are authorized to share the data.
    """))
    #expect(io.stdoutText.contains("I understand that my MCP client or agent may transmit LocalOCR inputs and results to an outside provider."))
    #expect(io.stdoutText.contains("I confirm that I am authorized to share this data and choose to enable LocalOCR MCP document tools."))
    #expect(io.stdoutText.contains("Accept external-provider transmission risk? [y/N]"))
    #expect(io.stdoutText.contains("Allow LocalOCR MCP document tools to access chosen files? [y/N]"))
}

@Test func mcpConsentAcceptFailsClosedWithoutAnInteractiveTerminal() async {
    let store = FixtureConsentStore()
    let io = FixtureConsentIO(isTerminal: false, answers: [])
    let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

    #expect(await harness.run(["mcp-consent", "accept"]) == 2)
    #expect(io.stderrText.contains("interactive terminal"))
    #expect(await store.acceptanceCount() == 0)
}

@Test func mcpConsentLeafHelpUsesLeafUsageWithoutTouchingConsent() async {
    for (operation, flag, expectedHelp) in [
        ("status", "--help", "Usage: localocr mcp-consent status\n"),
        ("status", "-h", "Usage: localocr mcp-consent status\n"),
        ("accept", "--help", "Usage: localocr mcp-consent accept\n\nRequires an interactive terminal and two confirmations.\n"),
        ("accept", "-h", "Usage: localocr mcp-consent accept\n\nRequires an interactive terminal and two confirmations.\n"),
        ("revoke", "--help", "Usage: localocr mcp-consent revoke\n"),
        ("revoke", "-h", "Usage: localocr mcp-consent revoke\n")
    ] {
        let store = FixtureConsentStore()
        let io = FixtureConsentIO(isTerminal: false, answers: [])
        let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

        #expect(await harness.run(["mcp-consent", operation, flag]) == 0)
        #expect(harness.stdout == expectedHelp)
        #expect(harness.stderr == "")
        #expect(await store.statusCalls() == 0)
        #expect(await store.acceptanceCount() == 0)
        #expect(await store.revocations() == 0)
        #expect(io.readLineCalls == 0)
    }
}

@Test func mcpConsentAcceptRejectsFlagsThatCouldBypassInteraction() async {
    let store = FixtureConsentStore()
    let io = FixtureConsentIO(isTerminal: true, answers: ["yes", "yes"])
    let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

    #expect(await harness.run(["mcp-consent", "accept", "--yes"]) == 2)
    #expect(await store.acceptanceCount() == 0)
}

@Test func mcpConsentRevokeWorksWithoutAnInteractiveTerminal() async {
    let store = FixtureConsentStore()
    let io = FixtureConsentIO(isTerminal: false, answers: [])
    let harness = CLIHarness(service: FixtureService(), consentStore: store, consentIO: io)

    #expect(await harness.run(["mcp-consent", "revoke"]) == 0)
    #expect(await store.revocations() == 1)
}

@Test func mcpConsentStoreFailuresUseTheOperationalExitCode() async {
    let io = FixtureConsentIO(isTerminal: true, answers: ["yes", "yes"])
    let harness = CLIHarness(
        service: FixtureService(),
        consentStore: FailingConsentStore(),
        consentIO: io
    )

    #expect(await harness.run(["mcp-consent", "accept"]) == 1)
    #expect(harness.stderr.contains("error:"))
}

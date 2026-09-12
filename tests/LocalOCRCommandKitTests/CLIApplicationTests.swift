import Darwin
import Foundation
import Testing
@testable import LocalOCRCommandKit
import LocalOCRIntelligence
import LocalOCRModelCore
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

@Test func intelligenceModelsUsesTheInjectedManagerAndReportsExactIdentity() async {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureApple, .fixtureOllama])
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    let status = await harness.run(["intelligence", "models"])

    #expect(status == 0)
    #expect(await manager.modelCalls() == 1)
    #expect(harness.stdout.contains("apple_foundation_models\tSystemLanguageModel.default"))
    #expect(harness.stdout.contains("ollama\tgemma4:8b"))
    #expect(harness.stderr == "")
}

@Test func intelligenceModelsJSONIsStableAndContainsOnlyDescriptorMetadata() async throws {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama, .fixtureApple])
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run(["intelligence", "models", "--json"]) == 0)

    let models = try #require(harness.stdoutJSON()["models"] as? [[String: Any]])
    #expect(models.count == 2)
    #expect(models[0]["provider"] as? String == "apple_foundation_models")
    #expect(models[0]["model"] as? String == "SystemLanguageModel.default")
    #expect(models[1]["provider"] as? String == "ollama")
    #expect(models[1]["model"] as? String == "gemma4:8b")
    #expect(models[1]["fingerprint"] as? String == "sha256:abc")
    #expect(models[1]["harness_version"] as? String == "0.13.0")
    #expect(models[1]["display_name"] as? String == "Gemma 4 8B")
    #expect(models[1]["locality"] as? String == "verified_local")
    #expect(models[1]["locality_reason"] as? String == "Verified local Ollama model.")
    #expect(models[1]["qualification"] as? String == "passed")
    #expect(models[1]["available"] as? Bool == true)
    #expect(models[1]["selected"] as? Bool == false)
    #expect(!harness.stdout.contains("user document sentinel"))
    #expect(harness.stderr == "")
}

@Test func intelligenceHumanOutputSanitizesEveryDescriptorDerivedFieldButJSONRemainsExact() async throws {
    let hostile = "visible\u{001B}\u{0000}\u{0008}\u{007F}\u{0085}\u{202E}\u{200B}\u{000D}\u{000A}\u{0009}\u{2028}\u{2029}end"
    let identity = LocalModelIdentity(
        provider: .ollama,
        model: hostile,
        fingerprint: hostile,
        harnessVersion: hostile
    )
    let descriptor = LocalModelDescriptor(
        identity: identity,
        displayName: hostile,
        locality: .verifiedLocal,
        localityReason: hostile,
        qualification: .passed,
        available: true,
        selected: false
    )
    let manager = FixtureIntelligenceManager(descriptors: [descriptor])
    let textHarness = CLIHarness(service: FixtureService(), intelligenceManager: manager)
    let jsonHarness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await textHarness.run(["intelligence", "models"]) == 0)
    #expect(!containsUnsafeTerminalScalar(textHarness.stdout, allowingSeparators: true))

    #expect(await jsonHarness.run(["intelligence", "models", "--json"]) == 0)
    let model = try #require((jsonHarness.stdoutJSON()["models"] as? [[String: Any]])?.first)
    #expect(model["model"] as? String == hostile)
    #expect(model["fingerprint"] as? String == hostile)
    #expect(model["harness_version"] as? String == hostile)
    #expect(model["display_name"] as? String == hostile)
    #expect(model["locality_reason"] as? String == hostile)
}

@Test func intelligenceInvalidProviderStatusPreservesTheExactProvider() async {
    let manager = FixtureIntelligenceManager(
        descriptors: [],
        selectionState: .invalid(.providerUnavailable(.lmStudio))
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run(["intelligence", "status", "--json"]) == 2)
    #expect(harness.stdoutJSON()["state"] as? String == "invalid")
    #expect(harness.stdoutJSON()["provider"] as? String == "lm_studio")
    #expect(harness.stdoutJSON()["failure"] as? String == "provider_unavailable")
}

@Test func intelligenceTestResolvesExactDescriptorAndReportsReceiptMetadata() async throws {
    let receipt = fixtureQualificationReceipt()
    let outcome = LocalModelQualificationOutcome(status: .passed, receipt: receipt, failures: [])
    let manager = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama],
        qualificationOutcomes: [LocalModelDescriptor.fixtureOllama.identity: outcome]
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run([
        "intelligence", "test", "ollama", "gemma4:8b", "--json"
    ]) == 0)

    #expect(await manager.qualifiedIdentities() == [LocalModelDescriptor.fixtureOllama.identity])
    let json = harness.stdoutJSON()
    #expect(json["provider"] as? String == "ollama")
    #expect(json["model"] as? String == "gemma4:8b")
    #expect(json["fingerprint"] as? String == "sha256:abc")
    #expect(json["harness_version"] as? String == "0.13.0")
    #expect(json["status"] as? String == "passed")
    #expect(json["failures"] as? [String] == [])
    #expect(json["qualified_at"] as? String == "2024-08-30T06:40:00Z")
    #expect(json["qualification_policy_version"] as? Int == 1)
    #expect(json["fixture_version"] as? Int == 1)
    #expect(json["passed_actions"] as? [String] == ["extraction", "organization", "summary"])
    #expect(harness.stderr == "")
}

// Catches CLI qualification that loses its role or groups its three owned probes into one lease.
@Test func intelligenceTestWritesExactlyThreeContentFreeCLILeases() async throws {
    let fixture = try CLIActivityFixture()
    defer { fixture.remove() }
    let reporter = CLIRecordingActivityReporter(underlying: fixture.reporter)
    let manager = CLIActivityManager(
        reporter: reporter,
        provider: CLIQualificationProvider(invalidExtraction: true)
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run([
        "intelligence", "test", "ollama", "gemma4:8b", "--json"
    ]) == 2)
    #expect(harness.stdoutJSON()["failures"] as? [String] == ["extraction"])

    let files = try fixture.activityFiles(in: "recent")
    let data = try files.map { try Data(contentsOf: $0) }
    let records = try data.map(LocalAIActivityContract.decode)
    #expect(await reporter.productTasks == [.summarize, .organize, .extract])
    #expect(try fixture.activityFiles(in: "active").isEmpty)
    #expect(records.count == 3)
    #expect(Set(records.map(\.activityID)).count == 3)
    #expect(records.allSatisfy { $0.producerRole == .cli })
    #expect(records.allSatisfy { $0.outcome == .success })
    #expect(cliQualificationRecordsHaveExactDescriptors(records))

    let encodedRecords = data.compactMap { String(data: $0, encoding: .utf8) }.joined()
    for forbidden in [
        "Invoice Q-104",
        "LocalOCR Qualification",
        "reference_number",
        "gemma4:8b",
        #""summary""#,
        #""organization""#,
        #""extraction""#,
    ] {
        #expect(!encodedRecords.contains(forbidden))
    }
}

// Catches CLI fixture input, output, model, URL, and error canaries entering qualification activity files.
@Test func intelligenceTestNeverWritesAnyContentCanaryToDisk() async throws {
    let fixture = try CLIActivityFixture()
    defer { fixture.remove() }
    let canaryPayload = cliPrivacyCanaries.joined(separator: " | ")
    let manager = CLIActivityManager(
        reporter: fixture.reporter,
        provider: CLIQualificationProvider(privacyPayload: canaryPayload)
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run([
        "intelligence", "test", "ollama", "gemma4:8b", "--json"
    ]) == 2)
    #expect(try fixture.activityFiles(in: "active").isEmpty)
    #expect(try fixture.activityFiles(in: "recent").count == 3)
    let allBytes = try fixture.allLedgerBytes()
    for canary in cliPrivacyCanaries {
        #expect(!allBytes.contains(Data(canary.utf8)))
    }
}

// Mutation proof: a decoded record with the wrong runtime must fail the CLI descriptor contract.
@Test func cliQualificationDescriptorProofRejectsAMutatedRuntime() throws {
    let records = try [
        cliActivityRecord(productTask: .summarize),
        cliActivityRecord(productTask: .organize, runtimeFamily: .coreML),
        cliActivityRecord(productTask: .extract),
    ].map { record in
        try LocalAIActivityContract.decode(LocalAIActivityContract.encode(record))
    }

    #expect(!cliQualificationRecordsHaveExactDescriptors(records))
}

// Catches discovery and selection management accidentally becoming model-activity claims.
@Test func modelsSelectStatusAndResetWriteNoCLIActivityRecords() async throws {
    let fixture = try CLIActivityFixture()
    defer { fixture.remove() }
    let reporter = CLIRecordingActivityReporter(underlying: fixture.reporter)
    let manager = CLIActivityManager(reporter: reporter)

    #expect(await CLIHarness(
        service: FixtureService(), intelligenceManager: manager
    ).run(["intelligence", "models", "--json"]) == 0)
    #expect(await CLIHarness(
        service: FixtureService(), intelligenceManager: manager
    ).run([
        "intelligence", "select", "apple_foundation_models", "SystemLanguageModel.default"
    ]) == 0)
    #expect(await CLIHarness(
        service: FixtureService(), intelligenceManager: manager
    ).run(["intelligence", "status", "--json"]) == 0)
    #expect(await CLIHarness(
        service: FixtureService(), intelligenceManager: manager
    ).run(["intelligence", "reset", "--json"]) == 0)

    #expect(await reporter.productTasks.isEmpty)
    #expect(try fixture.activityFiles(in: "active").isEmpty)
    #expect(try fixture.activityFiles(in: "recent").isEmpty)
}

// Catches a disabled or unavailable ledger changing the CLI qualification result.
@Test func intelligenceTestSurvivesReporterWriteFailure() async {
    let reporter = LocalAIActivityReporter(
        ledger: CLIFailingActivityLedger(),
        clock: SystemLocalAIActivityClock()
    )
    let manager = CLIActivityManager(reporter: reporter)
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run([
        "intelligence", "test", "ollama", "gemma4:8b", "--json"
    ]) == 0)
    #expect(harness.stdoutJSON()["status"] as? String == "passed")
}

@Test func intelligenceTestFailedOutcomeUsesInvalidExitAndStableText() async {
    let outcome = LocalModelQualificationOutcome(
        status: .failed,
        receipt: nil,
        failures: ["summary", "extraction"]
    )
    let manager = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama],
        qualificationOutcomes: [LocalModelDescriptor.fixtureOllama.identity: outcome]
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run(["intelligence", "test", "ollama", "gemma4:8b"]) == 2)
    #expect(harness.stdout == """
    Provider: Ollama
    Model: gemma4:8b
    Fingerprint: sha256:abc
    Harness version: 0.13.0
    Status: failed
    Failures: summary, extraction
    Qualified at: -
    Qualification policy: -
    Fixture version: -
    Passed actions: -
    """ + "\n")
}

@Test func intelligenceQualificationAndDisclosureSanitizeHostileFieldsWithoutChangingIdentity() async {
    let hostile = "visible\u{001B}\u{0000}\u{0008}\u{007F}\u{0085}\u{202E}\u{200B}\u{000D}\u{000A}\u{0009}\u{2028}\u{2029}end"
    let identity = LocalModelIdentity(
        provider: .ollama,
        model: hostile,
        fingerprint: hostile,
        harnessVersion: hostile
    )
    let descriptor = fixtureDescriptor(identity: identity, localityReason: hostile)
    let failed = LocalModelQualificationOutcome(status: .failed, receipt: nil, failures: [hostile])
    let testManager = FixtureIntelligenceManager(
        descriptors: [descriptor], qualificationOutcomes: [identity: failed]
    )
    let testHarness = CLIHarness(service: FixtureService(), intelligenceManager: testManager)

    #expect(await testHarness.run(["intelligence", "test", "ollama", hostile]) == 2)
    #expect(!containsUnsafeTerminalScalar(testHarness.stdout, allowingSeparators: true))

    let jsonHarness = CLIHarness(service: FixtureService(), intelligenceManager: testManager)
    #expect(await jsonHarness.run(["intelligence", "test", "ollama", hostile, "--json"]) == 2)
    #expect(jsonHarness.stdoutJSON()["model"] as? String == hostile)
    #expect(jsonHarness.stdoutJSON()["fingerprint"] as? String == hostile)
    #expect(jsonHarness.stdoutJSON()["harness_version"] as? String == hostile)
    #expect(jsonHarness.stdoutJSON()["failures"] as? [String] == [hostile])

    let selectManager = FixtureIntelligenceManager(descriptors: [descriptor])
    let io = FixtureConsentIO(isTerminal: true, answers: ["yes"])
    let selectHarness = CLIHarness(
        service: FixtureService(), intelligenceManager: selectManager, consentIO: io
    )
    #expect(await selectHarness.run(["intelligence", "select", "ollama", hostile]) == 0)
    #expect(!containsUnsafeTerminalScalar(io.stdoutText, allowingSeparators: true))
    #expect(await selectManager.externalSelections().first?.0 == identity)
}

@Test func intelligenceTestRejectsMissingDuplicateUnavailableAndUnsafeCandidatesWithoutQualifying() async {
    let cases: [[LocalModelDescriptor]] = [
        [],
        [.fixtureOllama, .fixtureOllama],
        [fixtureDescriptor(available: false)],
        [fixtureDescriptor(locality: .blocked, localityReason: "Cloud execution is blocked.")],
        [fixtureDescriptor(locality: .unverified, localityReason: "Locality could not be verified.")]
    ]
    for descriptors in cases {
        let manager = FixtureIntelligenceManager(descriptors: descriptors)
        let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

        #expect(await harness.run(["intelligence", "test", "ollama", "gemma4:8b"]) == 2)
        #expect(await manager.qualifiedIdentities().isEmpty)
    }
}

@Test func intelligenceSelectExternalPrintsExactDisclosureAndBindsAcceptanceTime() async {
    let acceptedAt = Date(timeIntervalSince1970: 1_730_000_000)
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
    let io = FixtureConsentIO(isTerminal: true, answers: ["yes"])
    let harness = CLIHarness(
        service: FixtureService(),
        intelligenceManager: manager,
        consentIO: io,
        now: { acceptedAt }
    )

    #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 0)

    #expect(io.stdoutText.hasPrefix("""
    LocalOCR will send OCR text to the selected third-party model harness over loopback on this Mac. The harness may keep its own logs or history. Review its privacy settings before continuing.
    Selected provider: Ollama
    Selected model: gemma4:8b
    Send future LocalOCR intelligence text to this local harness? [y/N]
    """))
    let selections = await manager.externalSelections()
    #expect(selections.count == 1)
    #expect(selections.first?.0 == LocalModelDescriptor.fixtureOllama.identity)
    #expect(selections.first?.1 == acceptedAt)
}

@Test func intelligenceSelectExternalRejectsNonterminalAndEveryNonexactAnswerWithoutMutation() async {
    let cases: [(Bool, [String?])] = [
        (false, ["yes"]), (true, []), (true, [nil]), (true, [""]),
        (true, ["Y"]), (true, ["YES"]), (true, ["Yes"]),
        (true, [" y"]), (true, ["y "]), (true, ["yes\nextra"]),
        (true, ["yes", "extra"]), (true, ["n"]), (true, ["no"])
    ]
    for (isTerminal, answers) in cases {
        let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
        let io = FixtureConsentIO(isTerminal: isTerminal, answers: answers)
        let harness = CLIHarness(
            service: FixtureService(),
            intelligenceManager: manager,
            consentIO: io
        )

        #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 2)
        #expect(await manager.externalSelections().isEmpty)
    }
}

@Test func legacyConsentIOConformerCompilesAndFailsClosedForExternalSelection() async {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
    let harness = CLIHarness(
        service: FixtureService(), intelligenceManager: manager, consentIO: LegacyConsentIO()
    )

    #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 2)
    #expect(await manager.externalSelections().isEmpty)
}

@Test func intelligenceSelectRereadsAndRejectsUnavailableUnsafeOrUnqualifiedCandidates() async {
    let cases: [LocalModelDescriptor] = [
        fixtureDescriptor(available: false),
        fixtureDescriptor(locality: .blocked),
        fixtureDescriptor(locality: .unverified),
        fixtureDescriptor(qualification: .untested),
        fixtureDescriptor(qualification: .failed),
        fixtureDescriptor(qualification: .stale)
    ]
    for descriptor in cases {
        let manager = FixtureIntelligenceManager(descriptors: [descriptor])
        let io = FixtureConsentIO(isTerminal: true, answers: ["yes"])
        let harness = CLIHarness(
            service: FixtureService(),
            intelligenceManager: manager,
            consentIO: io
        )

        #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 2)
        #expect(await manager.externalSelections().isEmpty)
        #expect(io.readLineCalls == 0)
    }
}

@Test func intelligenceSelectRejectsMissingDuplicateAndBypassFlagsWithoutMutation() async {
    let candidateCases: [[LocalModelDescriptor]] = [[], [.fixtureOllama, .fixtureOllama]]
    for descriptors in candidateCases {
        let manager = FixtureIntelligenceManager(descriptors: descriptors)
        let io = FixtureConsentIO(isTerminal: true, answers: ["yes"])
        let harness = CLIHarness(
            service: FixtureService(),
            intelligenceManager: manager,
            consentIO: io
        )
        #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 2)
        #expect(await manager.externalSelections().isEmpty)
        #expect(io.readLineCalls == 0)
    }

    for flag in ["--json", "--yes", "--force", "--noninteractive"] {
        let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
        let io = FixtureConsentIO(isTerminal: true, answers: ["yes"])
        let harness = CLIHarness(
            service: FixtureService(),
            intelligenceManager: manager,
            consentIO: io
        )
        #expect(await harness.run([
            "intelligence", "select", "ollama", "gemma4:8b", flag
        ]) == 2)
        #expect(await manager.externalSelections().isEmpty)
        #expect(io.readLineCalls == 0)
    }
}

@Test func intelligenceSelectAppleUsesExactTaskSixDescriptorWithoutPrompt() async {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureApple])
    let io = FixtureConsentIO(isTerminal: false, answers: [])
    let harness = CLIHarness(
        service: FixtureService(),
        intelligenceManager: manager,
        consentIO: io
    )

    #expect(await harness.run([
        "intelligence", "select", "apple_foundation_models", "SystemLanguageModel.default"
    ]) == 0)
    #expect(await manager.appleSelections() == 1)
    #expect(io.readLineCalls == 0)
    #expect(io.stdoutText == "selected apple_foundation_models SystemLanguageModel.default\n")
}

@Test func intelligenceSelectIdentityRaceFailsClosedWithoutPersistedMutation() async {
    let changed = LocalModelIdentity(
        provider: .ollama,
        model: "gemma4:8b",
        fingerprint: "sha256:changed",
        harnessVersion: "0.13.0"
    )
    let manager = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama],
        selectBehavior: .intelligenceFailure(.selection(.identityChanged(
            expected: LocalModelDescriptor.fixtureOllama.identity,
            actual: changed
        )))
    )
    let io = FixtureConsentIO(isTerminal: true, answers: ["y"])
    let harness = CLIHarness(
        service: FixtureService(),
        intelligenceManager: manager,
        consentIO: io
    )

    #expect(await harness.run(["intelligence", "select", "ollama", "gemma4:8b"]) == 2)
    #expect(await manager.externalSelections().isEmpty)
}

@Test func intelligenceStatusReportsNoneAppleExternalAndInvalidWithoutDiscovery() async throws {
    let resetAt = Date(timeIntervalSince1970: 1_730_000_000)
    let states: [(LocalIntelligenceSelectionState, String)] = [
        (.none, "none"),
        (.reset(at: resetAt), "reset"),
        (.selected(.appleSystemDefault), "selected"),
        (.selected(fixtureExternalSelection()), "selected"),
        (.invalid(.modelUnavailable(LocalModelDescriptor.fixtureOllama.identity)), "invalid")
    ]
    for (state, expected) in states {
        let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama], selectionState: state)
        let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

        #expect(await harness.run(["intelligence", "status", "--json"]) == (expected == "invalid" ? 2 : 0))
        #expect(harness.stdoutJSON()["state"] as? String == expected)
        #expect(await manager.statusCalls() == 1)
        #expect(await manager.modelCalls() == 0)
    }


    let resetManager = FixtureIntelligenceManager(descriptors: [], selectionState: .reset(at: resetAt))
    let textHarness = CLIHarness(service: FixtureService(), intelligenceManager: resetManager)
    #expect(await textHarness.run(["intelligence", "status"]) == 0)
    #expect(textHarness.stdout == "State: reset\nReset at: 2024-10-27T03:33:20Z\n")
}

@Test func intelligenceExternalStatusReportsExactQualificationAndAcknowledgment() async {
    let manager = FixtureIntelligenceManager(
        descriptors: [],
        selectionState: .selected(fixtureExternalSelection())
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run(["intelligence", "status"]) == 0)
    #expect(harness.stdout == """
    State: selected
    Provider: Ollama
    Model: gemma4:8b
    Fingerprint: sha256:abc
    Harness version: 0.13.0
    Qualification: passed
    Qualified at: 2024-08-30T06:40:00Z
    Qualification policy: 1
    Fixture version: 1
    Acknowledgment: current
    Acknowledged at: 2024-08-30T06:41:00Z
    Acknowledgment policy: 1
    """ + "\n")
    #expect(await manager.modelCalls() == 0)
}

@Test func intelligenceStatusSanitizesHostileSelectedIdentityFields() async {
    let hostile = "visible\u{001B}\u{0000}\u{0008}\u{007F}\u{0085}\u{202E}\u{200B}\u{000D}\u{000A}\u{0009}\u{2028}\u{2029}end"
    let identity = LocalModelIdentity(
        provider: .ollama, model: hostile, fingerprint: hostile, harnessVersion: hostile
    )
    let manager = FixtureIntelligenceManager(
        descriptors: [], selectionState: .selected(fixtureExternalSelection(identity: identity))
    )
    let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)

    #expect(await harness.run(["intelligence", "status"]) == 0)
    #expect(!containsUnsafeTerminalScalar(harness.stdout, allowingSeparators: true))

    let jsonHarness = CLIHarness(service: FixtureService(), intelligenceManager: manager)
    #expect(await jsonHarness.run(["intelligence", "status", "--json"]) == 0)
    #expect(jsonHarness.stdoutJSON()["model"] as? String == hostile)
    #expect(jsonHarness.stdoutJSON()["fingerprint"] as? String == hostile)
    #expect(jsonHarness.stdoutJSON()["harness_version"] as? String == hostile)
}

@Test func intelligenceResetIsStableIdempotentAndTouchesNeitherMCPConsentNorQualification() async {
    let consent = FixtureConsentStore()
    let manager = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama],
        selectionState: .selected(fixtureExternalSelection())
    )
    let first = CLIHarness(
        service: FixtureService(),
        intelligenceManager: manager,
        consentStore: consent
    )
    let second = CLIHarness(
        service: FixtureService(),
        intelligenceManager: manager,
        consentStore: consent
    )

    #expect(await first.run(["intelligence", "reset", "--json"]) == 0)
    #expect(first.stdout == "{\"state\":\"reset\"}\n")
    #expect(await second.run(["intelligence", "reset"]) == 0)
    #expect(second.stdout == "reset\n")
    #expect(await manager.resets() == 2)
    #expect(await manager.status() == .reset(at: Date(timeIntervalSince1970: 0)))
    #expect(await manager.qualifiedIdentities().isEmpty)
    #expect(await consent.statusCalls() == 0)
    #expect(await consent.revocations() == 0)
}

@Test func intelligenceResetSurvivesANewManagerAndStatusReportsPersistedTimestamp() async throws {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    try #require(realpath(FileManager.default.temporaryDirectory.path, &resolved) != nil)
    let physicalTemporaryDirectory = URL(
        fileURLWithPath: String(
            decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ),
        isDirectory: true
    )
    let baseURL = physicalTemporaryDirectory.appending(
        path: "LocalOCR-command-reset-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: false)
    try #require(chmod(baseURL.path, 0o700) == 0)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let receiptURL = baseURL
        .appending(path: "application", directoryHint: .isDirectory)
        .appending(path: "local-intelligence-selection.json")
    let resetAt = Date(timeIntervalSince1970: 1_730_000_000)
    let firstManager = StoreBackedIntelligenceManager(receiptURL: receiptURL, now: { resetAt })

    let first = CLIHarness(service: FixtureService(), intelligenceManager: firstManager)
    let second = CLIHarness(service: FixtureService(), intelligenceManager: firstManager)
    #expect(await first.run(["intelligence", "reset"]) == 0)
    #expect(await second.run(["intelligence", "reset", "--json"]) == 0)

    let relaunchedManager = StoreBackedIntelligenceManager(receiptURL: receiptURL, now: Date.init)
    let status = CLIHarness(service: FixtureService(), intelligenceManager: relaunchedManager)
    #expect(await status.run(["intelligence", "status", "--json"]) == 0)
    #expect(status.stdoutJSON()["state"] as? String == "reset")
    #expect(status.stdoutJSON()["reset_at"] as? String == "2024-10-27T03:33:20Z")
}

@Test func intelligenceExitCodesDistinguishCancellationInvalidAndOperationalFailures() async {
    let cancellation = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama], qualifyBehavior: .cancellation
    )
    let invalid = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama],
        qualifyBehavior: .intelligenceFailure(.selection(.qualificationRequired(
            LocalModelDescriptor.fixtureOllama.identity
        )))
    )
    let operational = FixtureIntelligenceManager(
        descriptors: [.fixtureOllama], qualifyBehavior: .operationalFailure
    )

    #expect(await CLIHarness(service: FixtureService(), intelligenceManager: cancellation).run([
        "intelligence", "test", "ollama", "gemma4:8b"
    ]) == 4)
    #expect(await CLIHarness(service: FixtureService(), intelligenceManager: invalid).run([
        "intelligence", "test", "ollama", "gemma4:8b"
    ]) == 2)
    #expect(await CLIHarness(service: FixtureService(), intelligenceManager: operational).run([
        "intelligence", "test", "ollama", "gemma4:8b"
    ]) == 1)
}

@Test func everyStableSelectionFailureUsesInvalidExitWithoutMutation() async {
    let identity = LocalModelDescriptor.fixtureOllama.identity
    let changed = LocalModelIdentity(
        provider: .ollama, model: identity.model,
        fingerprint: "sha256:changed", harnessVersion: identity.harnessVersion
    )
    let failures: [LocalIntelligenceSelectionFailure] = [
        .corruptReceipt,
        .providerUnavailable(.ollama),
        .modelUnavailable(identity),
        .localityUnverified(identity),
        .localityBlocked(identity),
        .qualificationRequired(identity),
        .acknowledgmentRequired(identity),
        .identityChanged(expected: identity, actual: changed)
    ]

    for failure in failures {
        let manager = FixtureIntelligenceManager(
            descriptors: [.fixtureOllama],
            qualifyBehavior: .intelligenceFailure(.selection(failure))
        )
        let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)
        #expect(await harness.run(["intelligence", "test", "ollama", "gemma4:8b"]) == 2)
        #expect(await manager.qualifiedIdentities().isEmpty)
        #expect(await manager.externalSelections().isEmpty)
        #expect(await manager.appleSelections() == 0)
        #expect(await manager.resets() == 0)
    }
}

@Test func selectAndResetMapCancellationAndOperationalFailureWithoutMutation() async {
    for (behavior, expected): (FixtureIntelligenceManagerBehavior, Int32) in [
        (.cancellation, 4), (.operationalFailure, 1)
    ] {
        let selectManager = FixtureIntelligenceManager(
            descriptors: [.fixtureOllama], selectBehavior: behavior
        )
        let selectHarness = CLIHarness(
            service: FixtureService(), intelligenceManager: selectManager,
            consentIO: FixtureConsentIO(isTerminal: true, answers: ["yes"])
        )
        #expect(await selectHarness.run([
            "intelligence", "select", "ollama", "gemma4:8b"
        ]) == expected)
        #expect(await selectManager.externalSelections().isEmpty)

        let resetManager = FixtureIntelligenceManager(
            descriptors: [], selectionState: .selected(.appleSystemDefault),
            resetBehavior: behavior
        )
        let resetHarness = CLIHarness(service: FixtureService(), intelligenceManager: resetManager)
        #expect(await resetHarness.run(["intelligence", "reset"]) == expected)
        #expect(await resetManager.resets() == 0)
        #expect(await resetManager.status() == .selected(.appleSystemDefault))
    }
}

@Test func ordinaryCLIHelpVersionAndOCRNeverTouchTheIntelligenceManager() async {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
    for arguments in [
        ["--help"], ["--version"], ["ocr", "/tmp/input.pdf"]
    ] {
        let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)
        #expect(await harness.run(arguments) == 0)
    }
    #expect(await manager.modelCalls() == 0)
    #expect(await manager.statusCalls() == 0)
    #expect(await manager.qualifiedIdentities().isEmpty)
    #expect(await manager.externalSelections().isEmpty)
    #expect(await manager.appleSelections() == 0)
    #expect(await manager.resets() == 0)
}

@Test func liveEnvironmentAndOrdinaryCLICommandsDoNotResolveTheBridgeHelper() async {
    let locator = FixtureBridgeLocator()
    let environment = LocalIntelligenceEnvironment.live(bridgeLocator: locator)

    for arguments in [["--help"], ["--version"], ["ocr", "/tmp/input.pdf"]] {
        let harness = CLIHarness(
            service: FixtureService(),
            intelligenceManager: environment.manager
        )
        #expect(await harness.run(arguments) == 0)
    }
    #expect(locator.resolutionCount == 0)

    let modelHarness = CLIHarness(
        service: FixtureService(),
        intelligenceManager: environment.manager
    )
    #expect(await modelHarness.run(["intelligence", "models", "--json"]) == 0)
    // Discovery resolves each external provider once: Ollama, LM Studio, llama.cpp.
    #expect(locator.resolutionCount == 3)
}

@Test func intelligenceRootGroupAndLeafHelpAreExactAndSideEffectFree() async {
    let manager = FixtureIntelligenceManager(descriptors: [.fixtureOllama])
    let cases = [
        (["intelligence", "--help"], "Usage: localocr intelligence <models|test|select|status|reset>\n"),
        (["intelligence", "models", "--help"], "Usage: localocr intelligence models [--json]\n"),
        (["intelligence", "test", "--help"], "Usage: localocr intelligence test <provider> <model> [--json]\n"),
        (["intelligence", "select", "--help"], "Usage: localocr intelligence select <provider> <model>\n"),
        (["intelligence", "status", "--help"], "Usage: localocr intelligence status [--json]\n"),
        (["intelligence", "reset", "--help"], "Usage: localocr intelligence reset [--json]\n")
    ]
    for (arguments, expected) in cases {
        let harness = CLIHarness(service: FixtureService(), intelligenceManager: manager)
        #expect(await harness.run(arguments) == 0)
        #expect(harness.stdout == expected)
        #expect(harness.stderr == "")
    }
    #expect(await manager.modelCalls() == 0)
    #expect(await manager.statusCalls() == 0)
    #expect(await manager.qualifiedIdentities().isEmpty)
    #expect(await manager.externalSelections().isEmpty)
    #expect(await manager.appleSelections() == 0)
    #expect(await manager.resets() == 0)
}

private func containsUnsafeTerminalScalar(
    _ value: String,
    allowingSeparators: Bool
) -> Bool {
    value.unicodeScalars.contains { scalar in
        if allowingSeparators && (scalar == "\n" || scalar == "\t") { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}

private actor CLIRecordingActivityReporter: LocalAIActivityReporting {
    private let underlying: any LocalAIActivityReporting
    private(set) var productTasks: [LocalAIProductTask?] = []

    init(underlying: any LocalAIActivityReporting) {
        self.underlying = underlying
    }

    func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        productTasks.append(descriptor.productTask)
        return try await underlying.withActivity(descriptor, operation: operation)
    }
}

private func cliQualificationRecordsHaveExactDescriptors(
    _ records: [LocalAIActivityRecord]
) -> Bool {
    let productTasks = records.compactMap(\.productTask).map(\.rawValue).sorted()
    guard records.count == 3,
          productTasks == ["extract", "organize", "summarize"]
    else {
        return false
    }
    return records.allSatisfy { record in
        record.producerID == LocalAIActivityContract.localOCRProducerID
            && record.producerRole == .cli
            && record.platform == .macos
            && record.runtimeFamily == .localRuntime
            && record.runtimeIdentifier == nil
            && record.route == .onDeviceLoopback
            && record.operation == .generation
            && record.outcome == .success
            && record.evidence == .participatingAppReported
    }
}

private func cliActivityRecord(
    productTask: LocalAIProductTask,
    runtimeFamily: LocalAIRuntimeFamily = .localRuntime
) -> LocalAIActivityRecord {
    let startedAt = Date(timeIntervalSince1970: 1_788_000_000)
    return LocalAIActivityRecord(
        schemaVersion: LocalAIActivityContract.schemaVersion,
        activityID: UUID(),
        producerID: LocalAIActivityContract.localOCRProducerID,
        producerRole: .cli,
        platform: .macos,
        runtimeFamily: runtimeFamily,
        runtimeIdentifier: nil,
        route: .onDeviceLoopback,
        operation: .generation,
        productTask: productTask,
        state: .ended,
        startedAt: startedAt,
        heartbeatAt: startedAt,
        expiresAt: startedAt.addingTimeInterval(86_400),
        endedAt: startedAt,
        outcome: .success,
        evidence: .participatingAppReported
    )
}

private actor CLIActivityManager: LocalIntelligenceManaging {
    private let qualification: LocalModelQualificationService
    private var selectionState: LocalIntelligenceSelectionState = .none

    init(
        reporter: any LocalAIActivityReporting,
        provider: CLIQualificationProvider = CLIQualificationProvider()
    ) {
        qualification = LocalModelQualificationService(
            providerFactory: { _ in provider },
            cacheDirectory: nil,
            activityReporter: reporter,
            producerRole: .cli,
            platform: .macos
        )
    }

    func models() async -> [LocalModelDescriptor] {
        [.fixtureApple, .fixtureOllama]
    }

    func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
        try await qualification.qualify(identity)
    }

    func selectApple() async throws {
        selectionState = .selected(.appleSystemDefault)
    }

    func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws {
        _ = identity
        _ = acknowledgmentAcceptedAt
    }

    func status() async -> LocalIntelligenceSelectionState { selectionState }

    func reset() async throws {
        selectionState = .reset(at: Date(timeIntervalSince1970: 0))
    }
}

private actor CLIQualificationProvider: DocumentIntelligenceProviding {
    nonisolated let availability: IntelligenceAvailability = .available
    private let invalidExtraction: Bool
    private let privacyPayload: String?
    private let provenance = LocalModelProvenance(
        provider: .ollama,
        providerDisplayName: "Ollama",
        model: "gemma4:8b",
        processing: .onDeviceLoopback,
        fingerprint: "sha256:abc",
        qualifiedAt: Date(timeIntervalSince1970: 1_725_000_000)
    )
    private var privacySuffix: String { privacyPayload.map { " \($0)" } ?? "" }

    init(invalidExtraction: Bool = false, privacyPayload: String? = nil) {
        self.invalidExtraction = invalidExtraction
        self.privacyPayload = privacyPayload
    }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        _ = document
        return .init(
            value: .init(
                text: "Invoice Q-104 totals $144.17 on 2026-08-29.\(privacySuffix)",
                citations: [.init(
                    page: 1,
                    quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.\(privacySuffix)"
                )]
            ),
            model: provenance
        )
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        _ = document
        return .init(
            value: .init(
                title: "Invoice Q-104\(privacySuffix)",
                category: "LocalOCR Qualification\(privacySuffix)",
                tags: ["synthetic test only", privacyPayload].compactMap { $0 },
                citations: [
                    .init(page: 1, quote: "Invoice Q-104"),
                    .init(page: 2, quote: "LocalOCR Qualification"),
                    .init(page: 2, quote: "synthetic test only"),
                ]
            ),
            model: provenance
        )
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        _ = names
        _ = document
        return .init(
            value: [
                .init(
                    name: "date", value: "2026-08-29", sourcePage: 1,
                    evidence: "Date: 2026-08-29"
                ),
                .init(
                    name: "total", value: "$144.17", sourcePage: 1,
                    evidence: "Total: $144.17\(privacySuffix)"
                ),
                .init(
                    name: "reference_number",
                    value: invalidExtraction ? nil : "Q-104",
                    sourcePage: invalidExtraction ? nil : 1,
                    evidence: invalidExtraction ? nil : "Invoice Q-104"
                ),
            ],
            model: provenance
        )
    }
}

private actor CLIFailingActivityLedger: LocalAIActivityLedgerWriting {
    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        _ = descriptor
        throw CLIActivityError.unavailable
    }
    func heartbeat(_ activityID: UUID) async throws { _ = activityID }
    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        _ = activityID
        _ = outcome
    }
    func cleanupExpired() async {}
}

private enum CLIActivityError: Error {
    case unavailable
}

private final class CLIActivityFixture: @unchecked Sendable {
    let containerURL: URL
    let reporter: LocalAIActivityReporter

    init() throws {
        containerURL = FileManager.default.temporaryDirectory.appending(
            path: "LocalOCR-cli-activity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: false)
        guard chmod(containerURL.path, 0o700) == 0 else { throw CLIActivityError.unavailable }
        let clock = SystemLocalAIActivityClock()
        reporter = LocalAIActivityReporter(
            ledger: LocalAIActivityLedger(containerURL: containerURL, clock: clock),
            clock: clock
        )
    }

    func activityFiles(in directory: String) throws -> [URL] {
        let url = containerURL
            .appending(path: "LocalAIActivity/v1", directoryHint: .isDirectory)
            .appending(path: directory, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    func allLedgerBytes() throws -> Data {
        let root = containerURL.appending(path: "LocalAIActivity", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return Data()
        }
        var bytes = Data()
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                bytes.append(try Data(contentsOf: url))
            }
        }
        return bytes
    }

    func remove() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}

private let cliPrivacyCanaries = [
    "SECRET OCR TEXT", "/Users/scott/private.pdf", "invoice.pdf",
    "prompt-canary", "response-canary", "total", "$9,999.00",
    "https://example.invalid", "model-error-canary",
]

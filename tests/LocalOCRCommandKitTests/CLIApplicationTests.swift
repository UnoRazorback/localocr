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
    let states: [(LocalIntelligenceSelectionState, String)] = [
        (.none, "none"),
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
    #expect(await manager.qualifiedIdentities().isEmpty)
    #expect(await consent.statusCalls() == 0)
    #expect(await consent.revocations() == 0)
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
    #expect(locator.resolutionCount == 2)
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

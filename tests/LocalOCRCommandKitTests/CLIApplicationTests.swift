import Testing
@testable import LocalOCRCommandKit
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
    for command in ["page-count", "inspect", "ocr", "batch", "image", "searchable"] {
        let harness = CLIHarness(service: FixtureService())

        #expect(await harness.run([command, "--help"]) == 0)
        #expect(harness.stdout.contains("Usage: localocr \(command)"))
        #expect(harness.stderr == "")
    }
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

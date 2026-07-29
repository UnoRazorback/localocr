import LocalOCRCore
import LocalOCRService
import Testing

@Suite(.serialized) struct CLIApplicationTests {
    @Test func inspectJSONUsesWireContractAndKeepsStderrEmpty() async throws {
        let harness = CLIHarness(service: .fixture(inspect: .success(.fixture)))
        let status = await harness.run(["inspect", "/tmp/input.pdf", "--json"])
        #expect(status == 0)
        #expect(try harness.stdoutJSON()["fully_searchable"] as? Bool == false)
        #expect(harness.stderr == "")
    }

    @Test func pageCountJSONUsesWireContract() async throws {
        let harness = CLIHarness()
        #expect(await harness.run(["page-count", "/tmp/input.pdf", "--json"]) == 0)
        #expect(try harness.stdoutJSON()["pages"] as? Int == 2)
    }

    @Test func versionPrintsTheRuntimeVersion() async {
        let harness = CLIHarness()
        #expect(await harness.run(["--version"]) == 0)
        #expect(harness.stdout == "0.2.0\n")
        #expect(harness.stderr == "")
    }

    @Test func everyCommandPrintsHelp() async {
        for command in ["page-count", "inspect", "ocr", "batch", "image", "searchable"] {
            let harness = CLIHarness()
            #expect(await harness.run([command, "--help"]) == 0)
            #expect(harness.stdout.contains(command))
            #expect(harness.stderr == "")
        }
    }

    @Test func ocrMapsAllRequestOptionsAndReportsProgressOnStderr() async throws {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["ocr", "/tmp/input.pdf", "--pages", "2-4", "--dpi", "300", "--force-ocr", "--detail", "--no-cache", "--json"]) == 0)
        let request = try #require(service.lastPDFRequest)
        #expect(request.pageRange == "2-4")
        #expect(request.dpi == 300)
        #expect(request.forceOCR)
        #expect(request.includeLines)
        #expect(!request.usesCache)
        #expect(harness.stderr.contains("recognizing"))
    }

    @Test func ocrUsesDefaultDPIAndWritesPageBoundariesInTextMode() async throws {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["ocr", "/tmp/input.pdf"]) == 0)
        #expect(try #require(service.lastPDFRequest).dpi == 250)
        #expect(harness.stdout == "--- Page 1 ---\nFirst page\n\n--- Page 2 ---\nSecond page\n")
    }

    @Test func partialOCRReturnsThree() async {
        let harness = CLIHarness(service: .fixture(ocr: .success(.fixture(failedPages: [2]))))
        #expect(await harness.run(["ocr", "/tmp/input.pdf", "--json"]) == 3)
    }

    @Test func humanPartialOCRKeepsTextOnStandardOutputAndReportsFailedPagesOnStandardError() async {
        let harness = CLIHarness(service: .fixture(ocr: .success(.fixture(failedPages: [2]))))
        #expect(await harness.run(["ocr", "/tmp/input.pdf"]) == 3)
        #expect(harness.stdout.contains("--- Page 1 ---"))
        #expect(harness.stderr.contains("failed pages: 2"))
    }

    @Test func malformedOCRPageSpecificationReturnsTwoBeforeCallingTheService() async {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["ocr", "/tmp/input.pdf", "--pages", "1-a"]) == 2)
        #expect(service.lastPDFRequest == nil)
        #expect(harness.stdout == "")
        #expect(harness.stderr.contains("pages"))
    }

    @Test func batchMapsOptionsAndUsesSourceHeadingsInTextMode() async throws {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf", "--pages", "1", "--dpi", "400", "--force-ocr", "--detail", "--no-cache"]) == 0)
        let request = try #require(service.lastBatchRequest)
        #expect(request.fileURLs.map(\.path) == ["/tmp/a.pdf", "/tmp/b.pdf"])
        #expect(request.pageRange == "1")
        #expect(request.dpi == 400)
        #expect(request.forceOCR && request.includeLines && !request.usesCache)
        #expect(harness.stdout.contains("--- /tmp/input.pdf ---"))
    }

    @Test func partialBatchReturnsThreeAndEncodesTheSharedResponse() async throws {
        let harness = CLIHarness(service: .fixture(batch: .partialFixture))
        #expect(await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf", "--json"]) == 3)
        #expect(try harness.stdoutJSON()["failed"] as? Int == 1)
    }

    @Test func shortenedBatchResponseReturnsFour() async {
        let harness = CLIHarness(service: .fixture(batch: .cancelledFixture))
        #expect(await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf", "--json"]) == 4)
    }

    @Test func malformedBatchPageSpecificationReturnsTwoBeforeCallingTheService() async {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["batch", "/tmp/a.pdf", "--pages", "1-a"]) == 2)
        #expect(service.lastBatchRequest == nil)
        #expect(harness.stdout == "")
        #expect(harness.stderr.contains("pages"))
    }

    @Test func humanBatchFailuresAreDiagnosticsOnStandardError() async {
        let harness = CLIHarness(service: .fixture(batch: .partialFixture))
        #expect(await harness.run(["batch", "/tmp/a.pdf", "/tmp/b.pdf"]) == 3)
        #expect(harness.stdout.contains("--- /tmp/input.pdf ---"))
        #expect(!harness.stdout.contains("/tmp/bad.pdf"))
        #expect(harness.stderr.contains("--- /tmp/bad.pdf ---\nunreadable"))
    }

    @Test func imageMapsLanguageAndCorrectionOptionsAndWritesPlainText() async throws {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["image", "/tmp/input.png", "--language", "en-US", "--language", "fr-FR", "--no-language-correction"]) == 0)
        let request = try #require(service.lastImageRequest)
        #expect(request.recognitionLanguages == ["en-US", "fr-FR"])
        #expect(!request.usesLanguageCorrection)
        #expect(harness.stdout == "recognized image\n")
    }

    @Test func searchableMapsOutputAndOptionsAndReportsItsNewPath() async throws {
        let service = FakeOCRService.fixture()
        let harness = CLIHarness(service: service)
        #expect(await harness.run(["searchable", "/tmp/input.pdf", "--output", "/tmp/new.pdf", "--dpi", "500", "--force-ocr", "--no-cache"]) == 0)
        let request = try #require(service.lastSearchableRequest)
        #expect(request.outputURL?.path == "/tmp/new.pdf")
        #expect(request.dpi == 500)
        #expect(request.forceOCR && !request.usesCache)
        #expect(harness.stdout == "/tmp/output.pdf\n")
    }

    @Test func partialSearchableReturnsThree() async {
        let harness = CLIHarness(service: .fixture(searchable: .success(.init(outputPath: "/tmp/output.pdf", failedPages: [1]))))
        #expect(await harness.run(["searchable", "/tmp/input.pdf", "--json"]) == 3)
    }

    @Test func humanPartialSearchableKeepsPathOnStandardOutputAndReportsFailedPagesOnStandardError() async {
        let harness = CLIHarness(service: .fixture(searchable: .success(.init(outputPath: "/tmp/output.pdf", failedPages: [1]))))
        #expect(await harness.run(["searchable", "/tmp/input.pdf"]) == 3)
        #expect(harness.stdout == "/tmp/output.pdf\n")
        #expect(harness.stderr.contains("failed pages: 1"))
    }

    @Test func malformedArgumentsReturnTwoAndKeepStandardOutputEmpty() async {
        let harness = CLIHarness()
        #expect(await harness.run(["ocr", "/tmp/input.pdf", "--dpi", "701"]) == 2)
        #expect(harness.stdout == "")
        #expect(harness.stderr.contains("dpi"))
    }

    @Test func operationErrorsReturnOne() async {
        let harness = CLIHarness(service: .fixture(inspect: .failure(.unreadablePDF)))
        #expect(await harness.run(["inspect", "/tmp/input.pdf"]) == 1)
        #expect(harness.stdout == "")
        #expect(!harness.stderr.isEmpty)
    }

    @Test func cancellationsReturnFour() async {
        let harness = CLIHarness(service: .fixture(image: .cancellation))
        #expect(await harness.run(["image", "/tmp/input.png"]) == 4)
        #expect(harness.stdout == "")
    }
}

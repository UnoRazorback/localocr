import Foundation
import LocalOCRCore
@testable import LocalOCRService
import PDFKit
import Testing

@Suite(.serialized) struct LocalOCRServiceTests {
    @Test func pageCountMapsThePDFInspectionPageCount() async throws {
        let response = try await LocalOCRService().pageCount(at: fixturePDF(named: "mixed"))

        #expect(response.pages == 2)
    }

    @Test func inspectionMapsCoreFieldsWithoutReorderingPages() async throws {
        let fileURL = fixturePDF(named: "mixed")

        let response = try await LocalOCRService().inspectPDF(at: fileURL)

        #expect(response.sourcePath == fileURL.path)
        #expect(response.pages == 2)
        #expect(response.searchablePages == 1)
        #expect(response.ocrNeededPages == 1)
        #expect(response.pageDetails.map(\.page) == [1, 2])
    }

    @Test func pdfOCRMapsExistingTextAndOmitsLinesWhenNotRequested() async throws {
        let request = try PDFOCRRequest(
            fileURL: fixturePDF(named: "mixed"),
            pageRange: "1",
            includeLines: false,
            usesCache: false
        )

        let response = try await LocalOCRService().ocrPDF(request)

        #expect(response.pages.map(\.page) == [1])
        #expect(response.pages.map(\.method) == [.existingText])
        #expect(response.pages.first?.lines == nil)
    }

    @Test func batchPreservesSuccessWhenAnotherInputFails() async throws {
        let invalidURL = try temporaryInvalidPDF()
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        let request = try BatchOCRRequest(
            fileURLs: [fixturePDF(named: "mixed"), invalidURL],
            pageRange: "1",
            usesCache: false
        )

        let result = await LocalOCRService().ocrPDFBatch(request)

        #expect(result.processed == 2)
        #expect(result.succeeded == 1)
        #expect(result.failed == 1)
        #expect(result.results.count == 2)
        #expect(result.results[0].isSuccess)
        #expect(result.results[1].isFailure(for: invalidURL.path))
    }

    @Test func batchDoesNotConstructACacheWhenTheRequestDisablesCaching() async throws {
        let recorder = BoolRecorder()
        let service = LocalOCRService(
            pdfSourceFactory: { FixturePDFSource() },
            processorFactory: { usesCache in
                recorder.record(usesCache)
                return OCRProcessor(
                    pdfSource: FixturePDFSource(),
                    recognizer: FixtureRecognizer(),
                    cache: nil
                )
            },
            writerFactory: { FixtureWriter() },
            imageSourceFactory: { ImageDocumentSource() }
        )
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let request = try BatchOCRRequest(fileURLs: [sourceURL], usesCache: false)

        let result = await service.ocrPDFBatch(request)

        #expect(result.succeeded == 1)
        #expect(recorder.values == [false])
    }

    @Test func defaultProcessorUsesTheRuntimeCachePathOnlyWhenCachingIsEnabled() async throws {
        let recorder = URLRecorder()
        let service = LocalOCRService(
            pdfSourceFactory: { FixturePDFSource() },
            writerFactory: { FixtureWriter() },
            imageSourceFactory: { ImageDocumentSource() },
            cacheURLProvider: { try LocalOCRRuntime.cacheURL() },
            cacheFactory: { url in
                recorder.record(url)
                return OCRCache(
                    rootURL: url,
                    compatibilityVersion: LocalOCRRuntime.version
                )
            }
        )
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        _ = try await service.ocrPDF(
            PDFOCRRequest(fileURL: sourceURL, usesCache: false)
        )
        #expect(recorder.values.isEmpty)

        _ = try await service.ocrPDF(
            PDFOCRRequest(fileURL: sourceURL, usesCache: true)
        )
        #expect(recorder.values == [try LocalOCRRuntime.cacheURL()])
    }

    @Test func cancelledWorkStopsBeforeItBuildsAnOCRProcessor() async throws {
        let recorder = BoolRecorder()
        let service = LocalOCRService(
            pdfSourceFactory: { FixturePDFSource() },
            processorFactory: { usesCache in
                recorder.record(usesCache)
                return OCRProcessor(
                    pdfSource: FixturePDFSource(),
                    recognizer: FixtureRecognizer(),
                    cache: nil
                )
            },
            writerFactory: { FixtureWriter() },
            imageSourceFactory: { ImageDocumentSource() }
        )
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let request = try PDFOCRRequest(fileURL: sourceURL)
        let task = Task { try await service.ocrPDF(request) }
        task.cancel()

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }
        #expect(recorder.values.isEmpty)
    }

    @Test func imageOCRRecognizesAnImageIODecodableFixture() async throws {
        let response = try await LocalOCRService().ocrImage(
            ImageOCRRequest(
                fileURL: fixtureImage(named: "sample"),
                recognitionLanguages: ["en-US"],
                usesLanguageCorrection: false
            )
        )

        #expect(response.text.contains("LOCAL OCR TEST 123"))
    }

    @Test func imageOCRMapsRecognizerCancellationToTheCoreError() async throws {
        let service = LocalOCRService(
            pdfSourceFactory: { FixturePDFSource() },
            processorFactory: { _ in
                OCRProcessor(
                    pdfSource: FixturePDFSource(),
                    recognizer: FixtureRecognizer(),
                    cache: nil
                )
            },
            writerFactory: { FixtureWriter() },
            imageSourceFactory: { CancellingImageSource() }
        )

        await #expect(throws: LocalOCRError.cancelled) {
            try await service.ocrImage(
                ImageOCRRequest(fileURL: fixtureImage(named: "sample"))
            )
        }
    }

    @Test func imageOCRRejectsUnsupportedInputBeforeBuildingTheRecognizer() async throws {
        let recorder = BoolRecorder()
        let service = LocalOCRService(
            pdfSourceFactory: { FixturePDFSource() },
            processorFactory: { _ in
                OCRProcessor(
                    pdfSource: FixturePDFSource(),
                    recognizer: FixtureRecognizer(),
                    cache: nil
                )
            },
            writerFactory: { FixtureWriter() },
            imageSourceFactory: {
                recorder.record(true)
                return ImageDocumentSource()
            }
        )
        let sourceURL = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        await #expect(throws: LocalOCRError.unsupportedFormat("txt")) {
            try await service.ocrImage(ImageOCRRequest(fileURL: sourceURL))
        }
        #expect(recorder.values.isEmpty)
    }

    @Test func searchablePDFCreatesASeparateValidDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: fixturePDF(named: "mixed"), to: sourceURL)
        let request = try SearchablePDFRequest(
            fileURL: sourceURL,
            usesCache: false
        )

        let response = try await LocalOCRService().makeSearchablePDF(request)

        #expect(response.outputPath != sourceURL.path)
        #expect(FileManager.default.fileExists(atPath: response.outputPath))
        #expect(PDFDocument(url: URL(fileURLWithPath: response.outputPath))?.pageCount == 2)
    }

    @Test func searchablePDFReportsAssemblyBeforeItsFinalCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: fixturePDF(named: "mixed"), to: sourceURL)
        let recorder = OCRProgressRecorder()

        _ = try await LocalOCRService().makeSearchablePDF(
            SearchablePDFRequest(fileURL: sourceURL, usesCache: false),
            progress: recorder.record
        )

        #expect(recorder.events.contains(.assembling))
        #expect(recorder.events.last == .completed)
    }

    @Test func searchablePDFRejectsAWriterThatReturnsAnotherURL() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = fixturePDF(named: "mixed")
        let outputURL = directory.appendingPathComponent("output.pdf")
        let service = fixtureService(writer: CopyingWriter(returnedURL: sourceURL))

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await service.makeSearchablePDF(
                SearchablePDFRequest(
                    fileURL: sourceURL,
                    outputURL: outputURL,
                    usesCache: false
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func searchablePDFMapsDirectWriterCancellationToTheCoreError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = fixtureService(writer: CancellingWriter())

        await #expect(throws: LocalOCRError.cancelled) {
            try await service.makeSearchablePDF(
                SearchablePDFRequest(
                    fileURL: fixturePDF(named: "mixed"),
                    outputURL: directory.appendingPathComponent("output.pdf"),
                    usesCache: false
                )
            )
        }
    }

    @Test func searchablePDFLeavesSourceBytesUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: fixturePDF(named: "mixed"), to: sourceURL)
        let original = try Data(contentsOf: sourceURL)
        let service = fixtureService(writer: CopyingWriter())

        _ = try await service.makeSearchablePDF(
            SearchablePDFRequest(fileURL: sourceURL, usesCache: false)
        )

        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test func searchablePDFRefusesAnExistingDestinationWithoutReplacingIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.pdf")
        let original = Data("existing output".utf8)
        try original.write(to: outputURL)
        let service = fixtureService(writer: CopyingWriter())

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await service.makeSearchablePDF(
                SearchablePDFRequest(
                    fileURL: fixturePDF(named: "mixed"),
                    outputURL: outputURL,
                    usesCache: false
                )
            )
        }
        #expect(try Data(contentsOf: outputURL) == original)
    }

    @Test func searchablePDFRefusesARacingDestinationAndCleansItsTemporaryFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: fixturePDF(named: "mixed"), to: sourceURL)
        let originalSource = try Data(contentsOf: sourceURL)
        let outputURL = directory.appendingPathComponent("output.pdf")
        let racingOutput = Data("racing destination".utf8)
        let temporaryURLs = URLRecorder()
        let service = fixtureService(
            writer: CopyingWriter(),
            beforePublication: { temporaryURL, destinationURL in
                temporaryURLs.record(temporaryURL)
                #expect(destinationURL == outputURL)
                try racingOutput.write(to: destinationURL, options: .withoutOverwriting)
            }
        )

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await service.makeSearchablePDF(
                SearchablePDFRequest(
                    fileURL: sourceURL,
                    outputURL: outputURL,
                    usesCache: false
                )
            )
        }

        #expect(try Data(contentsOf: outputURL) == racingOutput)
        #expect(try Data(contentsOf: sourceURL) == originalSource)
        let temporaryURL = try #require(temporaryURLs.values.first)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test func searchablePDFRejectsAnInvalidTemporaryWriterOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.pdf")
        let service = fixtureService(writer: InvalidWriter())

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await service.makeSearchablePDF(
                SearchablePDFRequest(
                    fileURL: fixturePDF(named: "mixed"),
                    outputURL: outputURL,
                    usesCache: false
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func searchablePDFUnionsOCRAndWriterFailedPages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = partialFailureService(writer: CopyingWriter(failedPages: [7]))

        let response = try await service.makeSearchablePDF(
            SearchablePDFRequest(
                fileURL: fixturePDF(named: "mixed"),
                outputURL: directory.appendingPathComponent("output.pdf"),
                usesCache: false
            )
        )

        #expect(response.failedPages == [2, 7])
    }
}

private extension BatchItemResponse {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    func isFailure(for sourcePath: String) -> Bool {
        if case let .failure(path, _) = self { return path == sourcePath }
        return false
    }
}

private final class BoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func record(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var values: [URL] {
        lock.withLock { storage }
    }

    func record(_ value: URL) {
        lock.withLock { storage.append(value) }
    }
}

private final class OCRProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OCRProgress] = []

    var events: [OCRProgress] {
        lock.withLock { storage }
    }

    func record(_ event: OCRProgress) {
        lock.withLock { storage.append(event) }
    }
}

private struct FixturePDFSource: PDFDocumentReading {
    func inspect(_ url: URL) throws -> PDFInspection {
        PDFInspection(
            pages: 1,
            searchablePages: [1],
            ocrNeededPages: [],
            characters: 20,
            fullySearchable: true,
            pageDetails: [PageInspection(page: 1, characters: 20, searchable: true)]
        )
    }

    func nativeText(in url: URL, pageIndex: Int) throws -> String { "fixture text" }
    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage { fatalError("Not used") }
}

private struct FixtureRecognizer: TextRecognizing {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        fatalError("Not used")
    }
}

private struct PartialFailurePDFSource: PDFDocumentReading {
    func inspect(_ url: URL) throws -> PDFInspection {
        PDFInspection(
            pages: 2,
            searchablePages: [1],
            ocrNeededPages: [2],
            characters: 20,
            fullySearchable: false,
            pageDetails: [
                PageInspection(page: 1, characters: 20, searchable: true),
                PageInspection(page: 2, characters: 0, searchable: false),
            ]
        )
    }

    func nativeText(in url: URL, pageIndex: Int) throws -> String { "fixture text" }

    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }
        return image
    }
}

private struct FailingRecognizer: TextRecognizing {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        throw LocalOCRError.recognitionFailed(page: 2, message: "fixture")
    }
}

private struct FixtureWriter: SearchablePDFWriting {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        fatalError("Not used")
    }
}

private struct CopyingWriter: SearchablePDFWriting {
    let returnedURL: URL?
    let failedPages: [Int]

    init(returnedURL: URL? = nil, failedPages: [Int] = []) {
        self.returnedURL = returnedURL
        self.failedPages = failedPages
    }

    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return SearchablePDFResult(
            outputURL: returnedURL ?? destinationURL,
            failedPages: failedPages,
            isComplete: failedPages.isEmpty
        )
    }
}

private struct InvalidWriter: SearchablePDFWriting {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        try Data("not a PDF".utf8).write(to: destinationURL)
        return SearchablePDFResult(
            outputURL: destinationURL,
            failedPages: [],
            isComplete: true
        )
    }
}

private struct CancellingWriter: SearchablePDFWriting {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        throw CancellationError()
    }
}

private struct CancellingImageSource: ImageDocumentRecognizing {
    func recognize(
        image: CGImage,
        settings: RecognitionSettings
    ) async throws -> String {
        throw CancellationError()
    }
}

private func fixturePDF(named name: String) -> URL {
    packageRoot
        .appendingPathComponent("tests/LocalOCRCoreTests/Fixtures/\(name).pdf")
}

private func fixtureService(
    writer: any SearchablePDFWriting,
    beforePublication: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
) -> LocalOCRService {
    LocalOCRService(
        pdfSourceFactory: { FixturePDFSource() },
        processorFactory: { _ in
            OCRProcessor(
                pdfSource: FixturePDFSource(),
                recognizer: FixtureRecognizer(),
                cache: nil
            )
        },
        writerFactory: { writer },
        imageSourceFactory: { ImageDocumentSource() },
        beforePublication: beforePublication
    )
}

private func partialFailureService(
    writer: any SearchablePDFWriting
) -> LocalOCRService {
    LocalOCRService(
        pdfSourceFactory: { PartialFailurePDFSource() },
        processorFactory: { _ in
            OCRProcessor(
                pdfSource: PartialFailurePDFSource(),
                recognizer: FailingRecognizer(),
                cache: nil
            )
        },
        writerFactory: { writer },
        imageSourceFactory: { ImageDocumentSource() }
    )
}

private func fixtureImage(named name: String) -> URL {
    packageRoot
        .appendingPathComponent("tests/LocalOCRServiceTests/Fixtures/\(name).png")
}

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func temporaryDirectory() throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func temporaryPDF() throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("fixture".utf8).write(to: url)
    return url
}

private func temporaryInvalidPDF() throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("not a PDF".utf8).write(to: url)
    return url
}

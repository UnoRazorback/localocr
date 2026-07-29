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

private struct FixtureWriter: SearchablePDFWriting {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        fatalError("Not used")
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

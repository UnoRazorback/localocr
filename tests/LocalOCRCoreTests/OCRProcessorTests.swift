import CoreGraphics
import Foundation
import ImageIO
import LocalOCRCore
import Testing

@Suite(.serialized) struct OCRProcessorTests {
    @Test func nativeTextPagesReturnExistingTextWithoutRecognition() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let pdf = FakePDFSource(
            inspection: inspection(pageCount: 1, searchablePages: [1]),
            nativeTexts: [0: "Already searchable"]
        )
        let recognizer = FakeTextRecognizer()
        let processor = OCRProcessor(pdfSource: pdf, recognizer: recognizer, cache: nil)

        let result = try await processor.process(request(sourceURL: sourceURL)) { _ in }

        #expect(result.pages == [
            PageResult(
                page: 1,
                text: "Already searchable",
                method: .existingText,
                lines: [],
                orientation: .up
            ),
        ])
        #expect(await recognizer.callCount == 0)
        #expect(pdf.rasterizedPages == [])
    }

    @Test func forceOCRRecognizesNativeTextPages() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let pdf = FakePDFSource(
            inspection: inspection(pageCount: 1, searchablePages: [1]),
            nativeTexts: [0: "Already searchable"]
        )
        let expected = candidate(.up, lines: ["Fresh OCR text"])
        let recognizer = FakeTextRecognizer(responses: [responseKey(page: 1, orientation: .up): .success(expected)])
        let processor = OCRProcessor(pdfSource: pdf, recognizer: recognizer, cache: nil)

        let result = try await processor.process(
            request(sourceURL: sourceURL, settings: .init(forceOCR: true))
        ) { _ in }

        #expect(result.pages.map(\.method) == [.visionOCR])
        #expect(result.pages.map(\.text) == ["Fresh OCR text"])
        #expect(await recognizer.recognizedPages == [1])
        #expect(pdf.rasterizedPages == [1])
    }

    @Test func processesOnlySelectedPages() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let pdf = FakePDFSource(
            inspection: inspection(pageCount: 4, searchablePages: [1, 2, 3, 4]),
            nativeTexts: [0: "one", 1: "two", 2: "three", 3: "four"]
        )
        let processor = OCRProcessor(pdfSource: pdf, recognizer: FakeTextRecognizer(), cache: nil)

        let result = try await processor.process(
            request(sourceURL: sourceURL, pageSelection: "4,2")
        ) { _ in }

        #expect(result.pages.map(\.page) == [2, 4])
        #expect(result.pages.map(\.text) == ["two", "four"])
        #expect(pdf.nativeTextPages == [2, 4])
        #expect(pdf.rasterizedPages == [])
    }

    @Test func cacheHitSkipsRasterizationAndRecognition() async throws {
        let sourceURL = try temporarySourceFile()
        let cacheRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let settings = RecognitionSettings(dpi: 300, recognitionLanguages: ["en-US"])
        let sourceHash = try await FileHashing.sha256(of: sourceURL)
        let cached = candidate(.left, lines: ["cached", "text"])
        let cache = OCRCache(rootURL: cacheRoot, compatibilityVersion: "test-v1")
        try await cache.store(
            cached,
            for: OCRCacheKey(
                sourceSHA256: sourceHash,
                page: 1,
                settings: settings,
                compatibilityVersion: "ignored-by-cache"
            )
        )
        let pdf = FakePDFSource(inspection: inspection(pageCount: 1))
        let recognizer = FakeTextRecognizer()
        let processor = OCRProcessor(pdfSource: pdf, recognizer: recognizer, cache: cache)

        let result = try await processor.process(request(sourceURL: sourceURL, settings: settings)) { _ in }

        #expect(result.pages.map(\.text) == ["cached\ntext"])
        #expect(result.pages.map(\.lines) == [cached.lines])
        #expect(result.rotatedOCRPages == [1: .left])
        #expect(pdf.rasterizedPages == [])
        #expect(await recognizer.callCount == 0)
    }

    @Test func recordsPageFailuresAndContinuesWithLaterPagesInSourceOrder() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let recognizer = FakeTextRecognizer(responses: [
            responseKey(page: 1, orientation: .up): .failure(.fixture),
            responseKey(page: 2, orientation: .up): .success(candidate(.up, lines: ["second page succeeds"])),
            responseKey(page: 3, orientation: .up): .failure(.fixture),
        ])
        let processor = OCRProcessor(
            pdfSource: FakePDFSource(inspection: inspection(pageCount: 3)),
            recognizer: recognizer,
            cache: nil
        )

        let result = try await processor.process(
            request(sourceURL: sourceURL, pageSelection: "3,1-2")
        ) { _ in }

        #expect(result.pages.map(\.page) == [2])
        #expect(result.pages.map(\.text) == ["second page succeeds"])
        #expect(result.failedPages == [1, 3])
    }

    @Test func classifiesBlankAndRotatedRecognitionAndPreservesVisionLines() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let rotated = candidate(.right, lines: ["rotated first", "rotated second"])
        let recognizer = FakeTextRecognizer(responses: [
            responseKey(page: 1, orientation: .up): .success(candidate(.up, lines: [])),
            responseKey(page: 2, orientation: .up): .success(candidate(.up, lines: ["x"], confidence: 0.1)),
            responseKey(page: 2, orientation: .right): .success(rotated),
        ])
        let processor = OCRProcessor(
            pdfSource: FakePDFSource(inspection: inspection(pageCount: 2)),
            recognizer: recognizer,
            cache: nil
        )

        let result = try await processor.process(request(sourceURL: sourceURL)) { _ in }

        #expect(result.pages.map(\.page) == [1, 2])
        #expect(result.pages[0].text == "")
        #expect(result.pages[0].lines == [])
        #expect(result.pages[1].text == "rotated first\nrotated second")
        #expect(result.pages[1].lines == rotated.lines)
        #expect(result.emptyOCRPages == [1])
        #expect(result.rotatedOCRPages == [2: .right])
    }

    @Test func reportsOrderedProgressForEverySelectedPage() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let recorder = ProgressRecorder()
        let processor = OCRProcessor(
            pdfSource: FakePDFSource(
                inspection: inspection(pageCount: 3, searchablePages: [1, 2, 3]),
                nativeTexts: [0: "one", 1: "two", 2: "three"]
            ),
            recognizer: FakeTextRecognizer(),
            cache: nil
        )

        _ = try await processor.process(
            request(sourceURL: sourceURL, pageSelection: "1,3"),
            progress: recorder.record
        )

        #expect(recorder.events == [
            .inspecting,
            .recognizing(page: 1, total: 2),
            .recognizing(page: 3, total: 2),
            .completed,
        ])
    }

    @Test func cancellationBetweenPagesThrowsCancelledAfterPriorCacheWrite() async throws {
        let sourceURL = try temporarySourceFile()
        let cacheRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let settings = RecognitionSettings()
        let first = candidate(.up, lines: ["first page cached"])
        let recognizer = FakeTextRecognizer(
            responses: [responseKey(page: 1, orientation: .up): .success(first)],
            cancelAfterRecognizedPage: 1
        )
        let cache = OCRCache(rootURL: cacheRoot, compatibilityVersion: "test-v1")
        let processor = OCRProcessor(
            pdfSource: FakePDFSource(inspection: inspection(pageCount: 2)),
            recognizer: recognizer,
            cache: cache
        )

        let processing = Task {
            try await processor.process(request(sourceURL: sourceURL, settings: settings)) { _ in }
        }

        await #expect(throws: LocalOCRError.cancelled) {
            try await processing.value
        }
        let sourceHash = try await FileHashing.sha256(of: sourceURL)
        let stored = try await cache.value(
            for: OCRCacheKey(
                sourceSHA256: sourceHash,
                page: 1,
                settings: settings,
                compatibilityVersion: "ignored-by-cache"
            )
        )
        #expect(stored == first)
        #expect(await recognizer.recognizedPages == [1])
    }

    @Test func rasterizationKeepsAtMostOneImageAlive() async throws {
        let sourceURL = try temporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let lifetime = ImageLifetimeTracker()
        let pdf = FakePDFSource(
            inspection: inspection(pageCount: 3),
            imageLifetime: lifetime
        )
        let recognizer = FakeTextRecognizer(responses: [
            responseKey(page: 1, orientation: .up): .success(candidate(.up, lines: ["first page text"])),
            responseKey(page: 2, orientation: .up): .success(candidate(.up, lines: ["second page text"])),
            responseKey(page: 3, orientation: .up): .success(candidate(.up, lines: ["third page text"])),
        ])
        let processor = OCRProcessor(pdfSource: pdf, recognizer: recognizer, cache: nil)

        let result = try await processor.process(request(sourceURL: sourceURL)) { _ in }

        #expect(result.pages.map(\.page) == [1, 2, 3])
        #expect(lifetime.maximumLiveImages == 1)
        #expect(lifetime.liveImages == 0)
    }
}

private func request(
    sourceURL: URL,
    pageSelection: String? = nil,
    settings: RecognitionSettings = .init()
) -> OCRRequest {
    OCRRequest(sourceURL: sourceURL, pageSelection: pageSelection, settings: settings)
}

private func inspection(pageCount: Int, searchablePages: Set<Int> = []) -> PDFInspection {
    let details = (1 ... pageCount).map {
        PageInspection(page: $0, characters: searchablePages.contains($0) ? 20 : 0, searchable: searchablePages.contains($0))
    }
    return PDFInspection(
        pages: pageCount,
        searchablePages: details.filter(\.searchable).map(\.page),
        ocrNeededPages: details.filter { !$0.searchable }.map(\.page),
        characters: details.reduce(0) { $0 + $1.characters },
        fullySearchable: details.allSatisfy(\.searchable),
        pageDetails: details
    )
}

private func candidate(
    _ orientation: CGImagePropertyOrientation,
    lines: [String],
    confidence: Float = 0.9
) -> RecognitionCandidate {
    RecognitionCandidate(
        orientation: orientation,
        lines: lines.map {
            TextLine(
                text: $0,
                confidence: confidence,
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            )
        }
    )
}

private struct RecognitionResponseKey: Hashable, Sendable {
    let page: Int
    let orientation: UInt32
}

private func responseKey(
    page: Int,
    orientation: CGImagePropertyOrientation
) -> RecognitionResponseKey {
    RecognitionResponseKey(page: page, orientation: orientation.rawValue)
}

private enum FakeRecognitionError: Error, Sendable {
    case fixture
}

private actor FakeTextRecognizer: TextRecognizing {
    private let responses: [RecognitionResponseKey: Result<RecognitionCandidate, FakeRecognitionError>]
    private let cancelAfterRecognizedPage: Int?
    private var calls: [RecognitionResponseKey] = []

    init(
        responses: [RecognitionResponseKey: Result<RecognitionCandidate, FakeRecognitionError>] = [:],
        cancelAfterRecognizedPage: Int? = nil
    ) {
        self.responses = responses
        self.cancelAfterRecognizedPage = cancelAfterRecognizedPage
    }

    var callCount: Int {
        calls.count
    }

    var recognizedPages: [Int] {
        calls.map(\.page)
    }

    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        let key = responseKey(page: image.width, orientation: orientation)
        calls.append(key)
        let response = responses[key] ?? .success(candidate(orientation, lines: []))
        let value = try response.get()
        if cancelAfterRecognizedPage == key.page {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return value
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [OCRProgress] = []

    func record(_ event: OCRProgress) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }

    var events: [OCRProgress] {
        lock.withLock { recordedEvents }
    }
}

private final class FakePDFSource: PDFDocumentReading, @unchecked Sendable {
    private let inspectionResult: PDFInspection
    private let nativeTexts: [Int: String]
    private let imageLifetime: ImageLifetimeTracker
    private let lock = NSLock()
    private var nativeTextPageIndexes: [Int] = []
    private var rasterizedPageIndexes: [Int] = []

    init(
        inspection: PDFInspection,
        nativeTexts: [Int: String] = [:],
        imageLifetime: ImageLifetimeTracker = ImageLifetimeTracker()
    ) {
        inspectionResult = inspection
        self.nativeTexts = nativeTexts
        self.imageLifetime = imageLifetime
    }

    func inspect(_ url: URL) throws -> PDFInspection {
        inspectionResult
    }

    func nativeText(in url: URL, pageIndex: Int) throws -> String {
        lock.withLock {
            nativeTextPageIndexes.append(pageIndex)
        }
        return nativeTexts[pageIndex] ?? ""
    }

    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage {
        lock.withLock {
            rasterizedPageIndexes.append(pageIndex)
        }
        return trackedImage(width: pageIndex + 1, lifetime: imageLifetime)
    }

    var nativeTextPages: [Int] {
        lock.withLock { nativeTextPageIndexes.map { $0 + 1 } }
    }

    var rasterizedPages: [Int] {
        lock.withLock { rasterizedPageIndexes.map { $0 + 1 } }
    }
}

private final class ImageLifetimeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    func acquired() {
        lock.withLock {
            current += 1
            maximum = max(maximum, current)
        }
    }

    func released() {
        lock.withLock {
            current -= 1
        }
    }

    var liveImages: Int {
        lock.withLock { current }
    }

    var maximumLiveImages: Int {
        lock.withLock { maximum }
    }
}

private final class TrackedImageAllocation {
    let bytes: UnsafeMutableRawPointer
    let lifetime: ImageLifetimeTracker

    init(byteCount: Int, lifetime: ImageLifetimeTracker) {
        bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
        bytes.initializeMemory(as: UInt8.self, repeating: 255, count: byteCount)
        self.lifetime = lifetime
        lifetime.acquired()
    }

    deinit {
        bytes.deallocate()
        lifetime.released()
    }
}

private func releaseTrackedImageData(
    info: UnsafeMutableRawPointer?,
    data: UnsafeRawPointer,
    size: Int
) {
    guard let info else { return }
    Unmanaged<TrackedImageAllocation>.fromOpaque(info).release()
}

private func trackedImage(width: Int, lifetime: ImageLifetimeTracker) -> CGImage {
    let bytesPerRow = width * 4
    let byteCount = bytesPerRow
    let allocation = TrackedImageAllocation(byteCount: byteCount, lifetime: lifetime)
    let info = Unmanaged.passRetained(allocation).toOpaque()
    let provider = CGDataProvider(
        dataInfo: info,
        data: allocation.bytes,
        size: byteCount,
        releaseData: releaseTrackedImageData
    )!
    return CGImage(
        width: width,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func temporarySourceFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OCRProcessorTests-\(UUID().uuidString).pdf")
    try Data("OCR processor fixture".utf8).write(to: url)
    return url
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OCRProcessorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

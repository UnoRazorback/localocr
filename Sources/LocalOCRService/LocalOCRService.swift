import Darwin
import Foundation
import LocalOCRCore
import PDFKit

public actor LocalOCRService: LocalOCRServing {
    private let pdfSourceFactory: @Sendable () -> any PDFDocumentReading
    private let processorFactory: (@Sendable (Bool) throws -> OCRProcessor)?
    private let writerFactory: @Sendable () -> any SearchablePDFWriting
    private let imageSourceFactory: @Sendable () -> any ImageDocumentRecognizing
    private let cacheURLProvider: @Sendable () throws -> URL
    private let cacheFactory: @Sendable (URL) -> OCRCache
    private let beforePublication: @Sendable (URL, URL) throws -> Void

    public init() {
        pdfSourceFactory = { PDFDocumentSource() }
        processorFactory = nil
        writerFactory = { SearchablePDFWriter() }
        imageSourceFactory = { ImageDocumentSource() }
        cacheURLProvider = { try LocalOCRRuntime.cacheURL() }
        cacheFactory = {
            OCRCache(
                rootURL: $0,
                compatibilityVersion: LocalOCRRuntime.version
            )
        }
        beforePublication = { _, _ in }
    }

    init(
        pdfSourceFactory: @escaping @Sendable () -> any PDFDocumentReading,
        processorFactory: @escaping @Sendable (Bool) throws -> OCRProcessor,
        writerFactory: @escaping @Sendable () -> any SearchablePDFWriting,
        imageSourceFactory: @escaping @Sendable () -> any ImageDocumentRecognizing,
        beforePublication: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) {
        self.pdfSourceFactory = pdfSourceFactory
        self.processorFactory = processorFactory
        self.writerFactory = writerFactory
        self.imageSourceFactory = imageSourceFactory
        cacheURLProvider = { try LocalOCRRuntime.cacheURL() }
        cacheFactory = {
            OCRCache(
                rootURL: $0,
                compatibilityVersion: LocalOCRRuntime.version
            )
        }
        self.beforePublication = beforePublication
    }

    init(
        pdfSourceFactory: @escaping @Sendable () -> any PDFDocumentReading,
        writerFactory: @escaping @Sendable () -> any SearchablePDFWriting,
        imageSourceFactory: @escaping @Sendable () -> any ImageDocumentRecognizing,
        cacheURLProvider: @escaping @Sendable () throws -> URL,
        cacheFactory: @escaping @Sendable (URL) -> OCRCache,
        beforePublication: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) {
        self.pdfSourceFactory = pdfSourceFactory
        processorFactory = nil
        self.writerFactory = writerFactory
        self.imageSourceFactory = imageSourceFactory
        self.cacheURLProvider = cacheURLProvider
        self.cacheFactory = cacheFactory
        self.beforePublication = beforePublication
    }

    public func pageCount(at fileURL: URL) async throws -> PageCountResponse {
        try checkCancellation()
        try validatePDFInput(fileURL)
        try checkCancellation()
        return PageCountResponse(pages: try pdfSourceFactory().inspect(fileURL).pages)
    }

    public func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse {
        try checkCancellation()
        try validatePDFInput(fileURL)
        try checkCancellation()
        let inspection = try pdfSourceFactory().inspect(fileURL)
        let sourceSHA256 = try await FileHashing.sha256(of: fileURL)
        return map(inspection, sourceURL: fileURL, sourceSHA256: sourceSHA256)
    }

    public func ocrPDF(
        _ request: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        let result = try await process(request, progress: progress)
        return map(result, sourceURL: request.fileURL, includeLines: request.includeLines)
    }

    public func ocrPDFBatch(
        _ request: BatchOCRRequest,
        progress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        var results: [BatchItemResponse] = []

        for (index, fileURL) in request.fileURLs.enumerated() {
            guard !Task.isCancelled else { break }
            let item = index + 1
            do {
                try checkCancellation()
                let response = try await ocrPDF(
                    PDFOCRRequest(
                        fileURL: fileURL,
                        pageRange: request.pageRange,
                        dpi: request.dpi,
                        forceOCR: request.forceOCR,
                        includeLines: request.includeLines,
                        usesCache: request.usesCache
                    ),
                    progress: { nested in
                        progress(
                            BatchProgress(
                                currentItem: item,
                                totalItems: request.fileURLs.count,
                                sourcePath: fileURL.path,
                                progress: nested
                            )
                        )
                    }
                )
                results.append(.success(response))
            } catch is CancellationError {
                break
            } catch let error as LocalOCRError where error == .cancelled {
                break
            } catch {
                results.append(.failure(sourcePath: fileURL.path, message: errorMessage(error)))
            }
        }

        return BatchOCRResponse(
            processed: results.count,
            succeeded: results.reduce(0) { $0 + ($1.isSuccess ? 1 : 0) },
            failed: results.reduce(0) { $0 + ($1.isSuccess ? 0 : 1) },
            results: results
        )
    }

    public func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        do {
            try checkCancellation()
            try validateLocalFile(request.fileURL)
            try checkCancellation()
            let image = try ImageDocumentSource.decodeImage(at: request.fileURL)
            try checkCancellation()
            let text = try await imageSourceFactory().recognize(
                image: image,
                settings: RecognitionSettings(
                    recognitionLanguages: request.recognitionLanguages,
                    usesLanguageCorrection: request.usesLanguageCorrection
                )
            )
            return ImageOCRResponse(text: text)
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        }
    }

    public func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        do {
            try checkCancellation()
            try validatePDFInput(request.fileURL)
            let outputURL = try resolveOutputURL(for: request)
            try validateOutput(outputURL, sourceURL: request.fileURL)

            let result = try await process(
                PDFOCRRequest(
                    fileURL: request.fileURL,
                    dpi: request.dpi,
                    forceOCR: request.forceOCR,
                    includeLines: true,
                    usesCache: request.usesCache
                ),
                progress: { event in
                    if event != .completed {
                        progress(event)
                    }
                }
            )
            try checkCancellation()
            progress(.assembling)

            let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
                ".\(outputURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial.pdf"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let writerResult = try await writerFactory().write(
                sourceURL: request.fileURL,
                destinationURL: temporaryURL,
                pageResults: result.pages
            )
            try checkCancellation()
            guard writerResult.outputURL.standardizedFileURL
                    == temporaryURL.standardizedFileURL,
                  PDFDocument(url: temporaryURL) != nil
            else {
                throw LocalOCRError.outputValidationFailed
            }
            try beforePublication(temporaryURL, outputURL)
            try moveWithoutOverwriting(temporaryURL, to: outputURL)
            progress(.completed)

            return SearchablePDFResponse(
                outputPath: outputURL.path,
                failedPages: Array(Set(result.failedPages).union(writerResult.failedPages)).sorted()
            )
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        }
    }

    private func process(
        _ request: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> OCRResult {
        try checkCancellation()
        try validatePDFInput(request.fileURL)
        try checkCancellation()
        let processor = try makeProcessor(usesCache: request.usesCache)
        return try await processor.process(
            OCRRequest(
                sourceURL: request.fileURL,
                pageSelection: request.pageRange,
                settings: RecognitionSettings(
                    dpi: request.dpi,
                    forceOCR: request.forceOCR
                )
            ),
            progress: progress
        )
    }

    private func makeProcessor(usesCache: Bool) throws -> OCRProcessor {
        if let processorFactory {
            return try processorFactory(usesCache)
        }
        let cache = try usesCache ? cacheFactory(cacheURLProvider()) : nil
        return OCRProcessor(
            pdfSource: pdfSourceFactory(),
            recognizer: VisionTextRecognizer(),
            cache: cache
        )
    }

    private func validatePDFInput(_ fileURL: URL) throws {
        try validateLocalFile(fileURL)
        guard fileURL.pathExtension.lowercased() == "pdf" else {
            throw LocalOCRError.unsupportedFormat(fileURL.pathExtension.lowercased())
        }
    }

    private func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw LocalOCRError.cancelled
        }
    }

    private func validateLocalFile(_ fileURL: URL) throws {
        guard fileURL.isFileURL else {
            throw LocalOCRError.unsupportedFormat(fileURL.scheme?.lowercased() ?? "")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalOCRError.fileNotFound
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard values.isRegularFile == true, values.isDirectory != true else {
            throw LocalOCRError.unsupportedFormat(fileURL.pathExtension.lowercased())
        }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.close()
        } catch {
            throw LocalOCRError.permissionDenied
        }
    }

    private func resolveOutputURL(for request: SearchablePDFRequest) throws -> URL {
        if let outputURL = request.outputURL {
            return outputURL
        }
        return OutputNaming.searchablePDFURL(for: request.fileURL) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func validateOutput(_ outputURL: URL, sourceURL: URL) throws {
        guard outputURL.isFileURL,
              outputURL.resolvingSymlinksInPath().standardizedFileURL
                != sourceURL.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw LocalOCRError.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw LocalOCRError.outputExists
        }
        let parent = outputURL.deletingLastPathComponent()
        guard
            (try? parent.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else {
            throw LocalOCRError.invalidDestination
        }
    }

    private func moveWithoutOverwriting(_ sourceURL: URL, to destinationURL: URL) throws {
        let status = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        if status == -1, errno == EEXIST {
            throw LocalOCRError.outputExists
        }
        guard status == 0 else {
            throw LocalOCRError.invalidDestination
        }
    }

    private func map(
        _ inspection: PDFInspection,
        sourceURL: URL,
        sourceSHA256: String
    ) -> InspectPDFResponse {
        InspectPDFResponse(
            sourcePath: sourceURL.path,
            sourceSHA256: sourceSHA256,
            pages: inspection.pages,
            searchablePages: inspection.searchablePages.count,
            ocrNeededPages: inspection.ocrNeededPages.count,
            characters: inspection.characters,
            fullySearchable: inspection.fullySearchable,
            pageDetails: inspection.pageDetails.map {
                PageInspectionResponse(page: $0.page, characters: $0.characters, searchable: $0.searchable)
            }
        )
    }

    private func map(
        _ result: OCRResult,
        sourceURL: URL,
        includeLines: Bool
    ) -> PDFOCRResponse {
        PDFOCRResponse(
            sourcePath: sourceURL.path,
            sourceSHA256: result.sourceSHA256,
            pages: result.pages.map { page in
                OCRPageResponse(
                    page: page.page,
                    text: page.text,
                    method: page.method == .existingText ? .existingText : .visionOCR,
                    lines: includeLines ? page.lines.map(map) : nil
                )
            },
            failedPages: result.failedPages,
            emptyOCRPages: result.emptyOCRPages,
            rotatedOCRPages: result.rotatedOCRPages.keys.sorted().compactMap { page in
                guard let orientation = result.rotatedOCRPages[page] else { return nil }
                return RotatedPageResponse(page: page, orientation: map(orientation))
            }
        )
    }

    private func map(_ line: TextLine) -> OCRLineResponse {
        OCRLineResponse(
            text: line.text,
            confidence: line.confidence,
            x: line.boundingBox.origin.x,
            y: line.boundingBox.origin.y,
            width: line.boundingBox.width,
            height: line.boundingBox.height
        )
    }

    private func map(_ orientation: CGImagePropertyOrientation) -> OCRPageOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        }
    }

    private func errorMessage(_ error: any Error) -> String {
        guard let error = error as? LocalOCRError else { return error.localizedDescription }
        return switch error {
        case .fileNotFound: "File not found"
        case let .unsupportedFormat(format): "Unsupported format: \(format)"
        case .imageDecodeFailed: "Image could not be decoded"
        case .permissionDenied: "Permission denied"
        case let .invalidPageSelection(selection): "Invalid page selection: \(selection)"
        case let .pageOutOfBounds(page, total): "Page \(page) is outside 1...\(total)"
        case .unreadablePDF: "PDF could not be read"
        case let .rasterizationFailed(page): "Could not rasterize page \(page)"
        case let .recognitionFailed(page, message): "Recognition failed on page \(page): \(message)"
        case .insufficientDiskSpace: "Insufficient disk space"
        case .invalidDestination: "Invalid output destination"
        case .outputExists: "Output already exists"
        case .outputValidationFailed: "Output validation failed"
        case .cancelled: "Cancelled"
        }
    }
}

private extension BatchItemResponse {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

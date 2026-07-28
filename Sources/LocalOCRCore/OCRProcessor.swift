import Foundation
import ImageIO

public actor OCRProcessor {
    private static let cacheCompatibilityVersion = "ocr-processor-v1"

    private let pdfSource: any PDFDocumentReading
    private let recognizer: any TextRecognizing
    private let cache: OCRCache?

    public init(
        pdfSource: any PDFDocumentReading,
        recognizer: any TextRecognizing,
        cache: OCRCache?
    ) {
        self.pdfSource = pdfSource
        self.recognizer = recognizer
        self.cache = cache
    }

    public func process(
        _ request: OCRRequest,
        progress: @Sendable (OCRProgress) -> Void
    ) async throws -> OCRResult {
        do {
            progress(.inspecting)
            try EngineErrorMapper.validatePDFSourceType(request.sourceURL)
            let sourceSHA256 = try await FileHashing.sha256(of: request.sourceURL)
            let inspection = try pdfSource.inspect(request.sourceURL)
            let selectedPages = try PageRange.parse(
                request.pageSelection,
                totalPages: inspection.pages
            )

            var pages: [PageResult] = []
            var failedPages: [Int] = []
            var emptyOCRPages: [Int] = []
            var rotatedOCRPages: [Int: CGImagePropertyOrientation] = [:]

            for pageIndex in selectedPages {
                try Task.checkCancellation()
                let page = pageIndex + 1
                progress(.recognizing(page: page, total: selectedPages.count))

                do {
                    if !request.settings.forceOCR,
                       inspection.searchablePages.contains(page)
                    {
                        let text = try pdfSource.nativeText(
                            in: request.sourceURL,
                            pageIndex: pageIndex
                        )
                        pages.append(
                            PageResult(
                                page: page,
                                text: text,
                                method: .existingText,
                                lines: [],
                                orientation: .up
                            )
                        )
                        continue
                    }

                    let key = OCRCacheKey(
                        sourceSHA256: sourceSHA256,
                        page: page,
                        settings: request.settings,
                        compatibilityVersion: Self.cacheCompatibilityVersion
                    )
                    let candidate: RecognitionCandidate
                    if let cache, let cached = try await cache.value(for: key) {
                        candidate = cached
                    } else {
                        candidate = try await recognize(
                            request.sourceURL,
                            pageIndex: pageIndex,
                            settings: request.settings
                        )
                        if let cache {
                            try await cache.store(candidate, for: key)
                        }
                    }

                    pages.append(
                        PageResult(
                            page: page,
                            text: candidate.text,
                            method: .visionOCR,
                            lines: candidate.lines,
                            orientation: candidate.orientation
                        )
                    )
                    if candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyOCRPages.append(page)
                    }
                    if candidate.orientation != .up {
                        rotatedOCRPages[page] = candidate.orientation
                    }
                } catch is CancellationError {
                    throw LocalOCRError.cancelled
                } catch let error as LocalOCRError where error == .cancelled {
                    throw error
                } catch {
                    failedPages.append(page)
                }
            }

            try Task.checkCancellation()
            progress(.completed)
            return OCRResult(
                sourceSHA256: sourceSHA256,
                pages: pages,
                failedPages: failedPages,
                emptyOCRPages: emptyOCRPages,
                rotatedOCRPages: rotatedOCRPages
            )
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        } catch {
            throw EngineErrorMapper.map(error, at: .source)
        }
    }

    func recognize(
        _ sourceURL: URL,
        pageIndex: Int,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        let image = try pdfSource.rasterize(
            sourceURL,
            pageIndex: pageIndex,
            dpi: settings.dpi
        )
        do {
            return try await OrientationSelector().best(
                image: image,
                settings: settings,
                recognizer: recognizer
            )
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        } catch let error as LocalOCRError {
            switch error {
            case .cancelled:
                throw error
            case let .recognitionFailed(_, message):
                throw LocalOCRError.recognitionFailed(
                    page: pageIndex + 1,
                    message: message
                )
            default:
                throw error
            }
        } catch {
            throw LocalOCRError.recognitionFailed(
                page: pageIndex + 1,
                message: error.localizedDescription
            )
        }
    }
}

import Foundation
import ImageIO

public actor OCRProcessor {
    // v3: recognized lines carry repaired amount punctuation.
    private static let cacheCompatibilityVersion = "ocr-processor-v3"

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
                    var recognized: RecognitionCandidate?
                    if !request.settings.forceOCR,
                       inspection.searchablePages.contains(page)
                    {
                        let text = try pdfSource.nativeText(
                            in: request.sourceURL,
                            pageIndex: pageIndex
                        )
                        // A stamp, header, or envelope ID on a scanned page passes the
                        // searchable test by itself. When embedded text is sparse, read
                        // the pixels too and keep whichever source carries the page.
                        if Self.isSparse(text) {
                            recognized = try await recognitionRicher(
                                than: text,
                                sourceURL: request.sourceURL,
                                sourceSHA256: sourceSHA256,
                                pageIndex: pageIndex,
                                settings: request.settings
                            )
                        }
                        if recognized == nil {
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
                    }

                    let candidate: RecognitionCandidate
                    if let recognized {
                        candidate = recognized
                    } else {
                        candidate = try await cachedRecognition(
                            sourceURL: request.sourceURL,
                            sourceSHA256: sourceSHA256,
                            pageIndex: pageIndex,
                            settings: request.settings
                        )
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

    /// Embedded text shorter than this is checked against the page's pixels.
    static let sparseNativeCharacterLimit = 400

    static func isSparse(_ nativeText: String) -> Bool {
        nonWhitespaceCount(nativeText) < sparseNativeCharacterLimit
    }

    /// Recognition replaces sparse embedded text only when it reads at least
    /// twice as much and at least 100 more characters, so a born-digital page
    /// with a short title keeps its exact embedded text.
    static func recognition(_ recognizedText: String, isRicherThan nativeText: String) -> Bool {
        let recognized = nonWhitespaceCount(recognizedText)
        let native = nonWhitespaceCount(nativeText)
        return recognized >= native * 2 && recognized - native >= 100
    }

    private static func nonWhitespaceCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !scalar.properties.isWhitespace {
                count += 1
            }
        }
    }

    private func recognitionRicher(
        than nativeText: String,
        sourceURL: URL,
        sourceSHA256: String,
        pageIndex: Int,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate? {
        let candidate: RecognitionCandidate
        do {
            candidate = try await cachedRecognition(
                sourceURL: sourceURL,
                sourceSHA256: sourceSHA256,
                pageIndex: pageIndex,
                settings: settings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalOCRError where error == .cancelled {
            throw error
        } catch {
            // The embedded text is still a valid answer for this page.
            return nil
        }
        return Self.recognition(candidate.text, isRicherThan: nativeText) ? candidate : nil
    }

    private func cachedRecognition(
        sourceURL: URL,
        sourceSHA256: String,
        pageIndex: Int,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        let key = OCRCacheKey(
            sourceSHA256: sourceSHA256,
            page: pageIndex + 1,
            settings: settings,
            compatibilityVersion: Self.cacheCompatibilityVersion
        )
        if let cache, let cached = try await cache.value(for: key) {
            return cached
        }
        let candidate = try await recognize(
            sourceURL,
            pageIndex: pageIndex,
            settings: settings
        )
        if let cache {
            try await cache.store(candidate, for: key)
        }
        return candidate
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

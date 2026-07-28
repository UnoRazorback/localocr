# LocalOCRCore Engine API

`LocalOCRCore` is a macOS 14+ Swift 6 library for local PDF inspection,
Apple Vision recognition, resumable page caching, and searchable-PDF output.
It has no UI, CLI, MCP, licensing, analytics, or networking dependency.

## Supported inputs and outputs

The high-level `OCRProcessor` accepts local PDF file URLs. It inspects native
PDF text, processes a one-indexed page selection, and returns an `OCRResult`.
`PDFDocumentSource` also exposes PDF inspection, native-text extraction, and
page rasterization. `VisionTextRecognizer` accepts any `CGImage`, so a future
CLI or app may decode macOS-supported image formats and call it directly.

The engine produces:

- structured page text, method, orientation, line confidence, and normalized
  line geometry in `OCRResult`;
- PDF text-layer inspection in `PDFInspection`;
- a new searchable PDF through `SearchablePDFWriter`.

The source is never overwritten by `SearchablePDFWriter`; source and
destination must be different local file URLs.

## Public types and protocols

These are the stable public declarations. Stored properties shown as `let`
are immutable; `RecognitionSettings` properties are configurable `var`s.

```swift
public struct RecognitionSettings: Sendable, Codable, Hashable {
    public var dpi: Int                         // default 250
    public var forceOCR: Bool                  // default false
    public var recognitionLanguages: [String] // default []
    public var usesLanguageCorrection: Bool    // default true
}

public struct OCRRequest: Sendable, Equatable {
    public let sourceURL: URL
    public let pageSelection: String?
    public let settings: RecognitionSettings
}

public struct PageInspection: Sendable, Codable, Equatable {
    public let page: Int
    public let characters: Int
    public let searchable: Bool
}

public struct PDFInspection: Sendable, Codable, Equatable {
    public let pages: Int
    public let searchablePages: [Int]
    public let ocrNeededPages: [Int]
    public let characters: Int
    public let fullySearchable: Bool
    public let pageDetails: [PageInspection]
}

public enum PageMethod: String, Sendable, Codable, Equatable {
    case existingText = "existing_text"
    case visionOCR = "vision_ocr"
}

public struct TextLine: Sendable, Codable, Equatable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect
}

public struct PageResult: Sendable, Codable, Equatable {
    public let page: Int
    public let text: String
    public let method: PageMethod
    public let lines: [TextLine]
    public let orientation: CGImagePropertyOrientation
}

public struct OCRResult: Sendable, Codable, Equatable {
    public let sourceSHA256: String
    public let pages: [PageResult]
    public let failedPages: [Int]
    public let emptyOCRPages: [Int]
    public let rotatedOCRPages: [Int: CGImagePropertyOrientation]
}

public enum OCRProgress: Sendable, Equatable {
    case inspecting
    case recognizing(page: Int, total: Int)
    case assembling
    case completed
}
```

The encoded contract uses snake-case keys (`source_sha256`,
`failed_pages`, `empty_ocr_pages`, `rotated_ocr_pages`,
`searchable_pages`, `ocr_needed_pages`, `fully_searchable`,
`page_details`, and `bounding_box`). Orientations encode as the raw
`CGImagePropertyOrientation` integer.

The public Swift `OCRResult` does not duplicate `OCRRequest.sourceURL` as a
stored path. Python-facing adapters that preserve the legacy response add
`source_path`; the cross-engine fixture exporter normalizes that adapter field
to `"<fixture>"` and the content hash to `"<sha256>"`.

```swift
public enum LocalOCRError: Error, Sendable, Equatable {
    case fileNotFound
    case unsupportedFormat(String)
    case permissionDenied
    case invalidPageSelection(String)
    case pageOutOfBounds(page: Int, total: Int)
    case unreadablePDF
    case rasterizationFailed(page: Int)
    case recognitionFailed(page: Int, message: String)
    case insufficientDiskSpace
    case invalidDestination
    case outputValidationFailed
    case cancelled
}

public enum PageRange {
    public static func parse(
        _ selection: String?,
        totalPages: Int
    ) throws -> [Int]
}

public enum OutputNaming {
    public static func searchablePDFURL(
        for source: URL,
        fileExists: (URL) -> Bool
    ) -> URL
}

public enum FileHashing {
    public static func sha256(of url: URL) async throws -> String
}
```

`PageRange.parse` accepts comma-separated pages and inclusive ranges such as
`"1-5"` and `"3,7,12"`. It returns sorted, deduplicated **zero-based page
indexes** for use with PDFKit. A `nil` selection returns every page.
`OutputNaming` returns `<stem>_searchable.pdf`, then
`<stem>_searchable_2.pdf` and higher collision-free names.

```swift
public protocol PDFDocumentReading: Sendable {
    func inspect(_ url: URL) throws -> PDFInspection
    func nativeText(in url: URL, pageIndex: Int) throws -> String
    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage
}

public struct PDFDocumentSource: PDFDocumentReading {
    public static let minimumNativeCharacters = 20
    public init()
    public func inspect(_ url: URL) throws -> PDFInspection
    public func nativeText(in url: URL, pageIndex: Int) throws -> String
    public func rasterize(
        _ url: URL,
        pageIndex: Int,
        dpi: Int
    ) throws -> CGImage
}

public struct RecognitionCandidate: Sendable, Equatable {
    public let orientation: CGImagePropertyOrientation
    public let lines: [TextLine]
    public var text: String { get }
}

public protocol TextRecognizing: Sendable {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate
}

public struct VisionTextRecognizer: TextRecognizing {
    public init()
    public func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate
}

public struct OrientationSelector {
    public init()
    public func best(
        image: CGImage,
        settings: RecognitionSettings,
        recognizer: any TextRecognizing
    ) async throws -> RecognitionCandidate
}
```

Vision recognition uses `.accurate` mode. The selector accepts the upright
candidate without retries when it has at least 12 non-whitespace characters
and mean confidence of at least `0.55`. Otherwise it tries `.right`, `.down`,
and `.left`, chooses the highest character/confidence score, and keeps the
earlier candidate on an exact tie.

```swift
public struct OCRCacheKey: Sendable, Codable, Hashable {
    public let sourceSHA256: String
    public let page: Int
    public let settings: RecognitionSettings
    public let compatibilityVersion: String
}

public actor OCRCache {
    public init(rootURL: URL, compatibilityVersion: String)
    public func value(for key: OCRCacheKey) throws -> RecognitionCandidate?
    public func store(
        _ value: RecognitionCandidate,
        for key: OCRCacheKey
    ) throws
    public func removeAll() throws
}

public actor OCRProcessor {
    public init(
        pdfSource: any PDFDocumentReading,
        recognizer: any TextRecognizing,
        cache: OCRCache?
    )
    public func process(
        _ request: OCRRequest,
        progress: @Sendable (OCRProgress) -> Void
    ) async throws -> OCRResult
}
```

```swift
public struct SearchablePDFResult: Sendable, Equatable {
    public let outputURL: URL
    public let failedPages: [Int]
    public let isComplete: Bool
}

public protocol SearchablePDFWriting: Sendable {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult
}

public struct SearchablePDFWriter: SearchablePDFWriting {
    public init(pdfReader: any PDFDocumentReading = PDFDocumentSource())
    public func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult
}
```

## Page numbering and native-text threshold

Public results, progress events, errors, cache keys used by the processor,
and page-selection strings are one-indexed. The low-level
`PDFDocumentReading.nativeText` and `rasterize` protocol methods use
zero-based `pageIndex` values to match PDFKit.

After trimming leading and trailing whitespace/newlines, a PDF page is
searchable at **20 characters or more**. Unless `forceOCR` is `true`, such a
page is returned as `.existingText` with an empty `lines` array and `.up`
orientation; Vision and rasterization are skipped.

## Progress and cancellation

`OCRProcessor.process` calls the supplied synchronous `@Sendable` closure in
this order:

1. `.inspecting`
2. `.recognizing(page:total:)` once for every selected page, including
   native-text and cache-hit pages
3. `.completed` after all selected pages finish

`total` is the number of selected pages, not the PDF page count.
`.assembling` is part of the stable progress type for output-layer
integration, but `OCRProcessor.process` does not currently emit it.

The processor checks task cancellation between pages and before completion.
The searchable-PDF writer checks before and during assembly, validation, and
destination replacement. Cancellation is reported as
`LocalOCRError.cancelled`, never as a failed page. Successful cache writes
from earlier pages remain available. Vision itself is not interrupted
mid-request; cancellation is observed at the next engine checkpoint.

## Cache identity and clearing

The cache file identity is a SHA-256 of sorted JSON containing:

- source content SHA-256;
- one-indexed page number;
- all `RecognitionSettings` fields, including DPI, force-OCR, languages,
  and language correction;
- the `OCRCache` instance's compatibility version.

The cache instance's configured compatibility version is authoritative; it
replaces the version carried by a supplied `OCRCacheKey` before hashing.
Entries are sharded by the first two digest characters and written through a
unique temporary sibling. Cache directories are restricted to mode `0700`.
A corrupt JSON entry is removed and treated as a miss, while operational read
errors are thrown. `removeAll()` removes the configured cache root and is a
no-op when it does not exist. Pass `cache: nil` to disable cache reads/writes.
The library chooses no default cache location; the app or executable owns
that policy.

## Partial-failure guarantees

After a request has been opened, hashed, inspected, and parsed, an individual
page error is appended to `failedPages` and later pages continue. Failed
pages are omitted from `pages`. A successful Vision request with no text is
returned in `pages` and separately listed in `emptyOCRPages`. A successful
non-upright result is listed in `rotatedOCRPages`. Result and failure arrays
follow ascending source-page order.

Source-level failures (missing/unreadable input, hashing or inspection
failure, or invalid selection) throw and return no `OCRResult`. Cancellation
also throws. For searchable-PDF output, omitted page results are copied
visually unchanged and listed in `SearchablePDFResult.failedPages`;
`isComplete` is false. The writer validates a temporary output before
atomically moving/replacing the destination and cleans up its temporary
files on handled failure.

## Searchable-PDF coordinates and numeric accuracy

Vision line boxes are normalized `0...1` rectangles with a lower-left origin
in the candidate orientation's coordinate space. The writer maps `.right`,
`.down`, and `.left` boxes back to the source orientation, scales them to the
PDF media box, applies the PDF page transform (including page rotation and
non-zero origins), and draws fitted Helvetica text invisibly. Existing native
text is not duplicated. Media/crop/bleed/trim/art boxes, page rotation, and
the original visual appearance are preserved.

The invisible overlay is line-box fitted, not glyph-for-glyph typesetting.
Text selection bounds are therefore approximate. OCR confidence and geometry
are recognition results, and digits, currency symbols, and other
financially significant values require source-document verification; they
must not be treated as authoritative numeric data.

## Minimal PDF processing example

```swift
import Foundation
import LocalOCRCore

@main
struct Example {
    static func main() async throws {
        let source = URL(fileURLWithPath: "/path/to/document.pdf")
        let processor = OCRProcessor(
            pdfSource: PDFDocumentSource(),
            recognizer: VisionTextRecognizer(),
            cache: nil
        )
        let result = try await processor.process(
            OCRRequest(
                sourceURL: source,
                pageSelection: nil,
                settings: RecognitionSettings()
            )
        ) { progress in
            print(progress)
        }

        for page in result.pages {
            print("Page \(page.page) [\(page.method.rawValue)]")
            print(page.text)
        }
    }
}
```

# LocalOCR Swift Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify an open-source native Swift package that matches the current Python OCR engine's observable behavior and can later power the CLI, MCP server, and SwiftUI app.

**Architecture:** Add a Swift Package Manager workspace beside the existing Python reference. `LocalOCRCore` owns platform-neutral models and orchestration, while focused adapters wrap Vision, PDFKit/Core Graphics, caching, and searchable-PDF output behind protocols. The Python implementation remains unchanged as the behavioral oracle until Swift contract and fixture tests pass.

**Tech Stack:** Swift 6, Swift Package Manager, macOS 14+, XCTest/Swift Testing, Vision, PDFKit, Core Graphics, CryptoKit, UniformTypeIdentifiers; existing Python 3.12/PyObjC/PyMuPDF tests remain the reference suite.

## Global Constraints

- macOS only; deployment target is macOS 14.0.
- Swift language mode is Swift 6 with strict concurrency enabled.
- Document contents, OCR text, filenames, thumbnails, paths, and hashes never cross a network boundary.
- The engine package contains no networking, analytics, licensing, UI, MCP, or client-configuration code.
- Original input files are immutable; transformed documents are written to a new file.
- Default PDF rasterization is 250 DPI.
- Pages with at least 20 native text characters are not OCRed unless `forceOCR` is true.
- PDF page specifications are one-indexed and accept forms such as `1-5` and `3,7,12`.
- Processing is page-by-page with bounded memory, progress reporting, cancellation, partial results, and resumability.
- Cache identity includes content SHA-256, page number, DPI, relevant recognition settings, and engine compatibility version.
- OCR output is recognition data, not authoritative financial data; confidence remains available to consumers.
- No source file or production fixture may contain private customer documents.
- Do not remove or rewrite the Python reference implementation during this plan.

---

## Planned File Structure

```text
Package.swift
Sources/
  LocalOCRCore/
    Models.swift                 Shared value types and stable public API
    LocalOCRError.swift          Structured engine errors
    PageRange.swift              One-indexed page-selection parser
    OutputNaming.swift           Collision-safe output URL policy
    FileHashing.swift            Streaming SHA-256
    PDFDocumentSource.swift      PDF inspection and page rasterization
    VisionTextRecognizer.swift   Apple Vision adapter
    OrientationSelector.swift    Rotation scoring and selection
    OCRCache.swift               Actor-backed content-addressed cache
    SearchablePDFWriter.swift    Invisible text-layer output
    OCRProcessor.swift           Incremental orchestration and progress
Tests/
  LocalOCRCoreTests/
    Fixtures/
    ContractFixtures.swift
    PageRangeTests.swift
    OutputNamingTests.swift
    FileHashingTests.swift
    PDFDocumentSourceTests.swift
    VisionTextRecognizerTests.swift
    OrientationSelectorTests.swift
    OCRCacheTests.swift
    SearchablePDFWriterTests.swift
    OCRProcessorTests.swift
scripts/
  generate-contract-fixtures.py
  compare-engine-contracts.py
```

`LocalOCRCore` is the only library target. Each adapter has one responsibility
and conforms to a protocol declared beside the public models it consumes.

---

### Task 1: Freeze the Python Behavioral Contract and Add the Swift Package

**Files:**
- Create: `scripts/generate-contract-fixtures.py`
- Create: `tests/contract/test_engine_contract.py`
- Create: `tests/contract/expected/inspect_mixed.json`
- Create: `tests/contract/expected/ocr_existing_text.json`
- Create: `Package.swift`
- Create: `Sources/LocalOCRCore/Models.swift`
- Create: `Sources/LocalOCRCore/LocalOCRError.swift`
- Create: `Tests/LocalOCRCoreTests/ContractFixtures.swift`

**Interfaces:**
- Consumes: Existing `ocr_service.core`, `ocr_service.pdf_utils`, and synthetic fixture builders from `tests/conftest.py`.
- Produces: `LocalOCRCore` Swift library; stable models `OCRRequest`, `PageResult`, `OCRResult`, `TextLine`, `PageInspection`, `PDFInspection`, `RecognitionSettings`, `OCRProgress`, and `LocalOCRError`.

- [ ] **Step 1: Add a failing Python contract test**

```python
def test_contract_fixture_generator_is_deterministic(contract_fixture_dir):
    first = generate_contract_fixtures(contract_fixture_dir)
    second = generate_contract_fixtures(contract_fixture_dir)
    assert first == second
    assert first["inspect_mixed"]["ocr_needed_pages"] == [2]
    assert first["ocr_existing_text"]["pages"][0]["method"] == "existing_text"
```

- [ ] **Step 2: Run the contract test and verify failure**

Run: `.venv/bin/python -m pytest tests/contract/test_engine_contract.py -v`

Expected: FAIL because `generate_contract_fixtures` and the expected JSON files do not exist.

- [ ] **Step 3: Implement deterministic reference fixture generation**

Create `scripts/generate-contract-fixtures.py` using the existing synthetic
fixture helpers and normalize machine-specific paths before writing JSON:

```python
def normalize(result: dict) -> dict:
    result = dict(result)
    result["source_path"] = "<fixture>"
    result["source_sha256"] = "<sha256>"
    return result
```

Generate one mixed PDF inspection result and one native-text OCR result. Sort
JSON keys, use two-space indentation, and terminate files with a newline.

- [ ] **Step 4: Run the full Python reference suite**

Run: `.venv/bin/python -m pytest -v`

Expected: All existing tests and the new contract test PASS.

- [ ] **Step 5: Add the Swift package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalOCR",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocalOCRCore", targets: ["LocalOCRCore"])],
    targets: [
        .target(
            name: "LocalOCRCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRCoreTests",
            dependencies: ["LocalOCRCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
```

- [ ] **Step 6: Define the stable engine models**

Create immutable `Sendable`, `Codable`, and `Equatable` structs and enums. Use
these exact public signatures:

```swift
public struct RecognitionSettings: Sendable, Codable, Hashable {
    public var dpi: Int = 250
    public var forceOCR: Bool = false
    public var recognitionLanguages: [String] = []
    public var usesLanguageCorrection: Bool = true
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

public enum PageMethod: String, Sendable, Codable {
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

Add custom `Codable` handling for `CGRect` and `CGImagePropertyOrientation`
where synthesized conformance is unavailable.

- [ ] **Step 7: Define structured errors**

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
```

- [ ] **Step 8: Add Swift model round-trip tests**

Test JSON round trips for every model, snake-case raw values for `PageMethod`,
and equality of the reconstructed values.

Run: `swift test --filter ContractFixtures`

Expected: PASS.

- [ ] **Step 9: Commit the contract baseline**

```bash
git add Package.swift Sources/LocalOCRCore Tests/LocalOCRCoreTests scripts tests/contract
git commit -m "test: freeze OCR engine contract"
```

---

### Task 2: Page Selection, Output Naming, and Streaming Hashes

**Files:**
- Create: `Sources/LocalOCRCore/PageRange.swift`
- Create: `Sources/LocalOCRCore/OutputNaming.swift`
- Create: `Sources/LocalOCRCore/FileHashing.swift`
- Create: `Tests/LocalOCRCoreTests/PageRangeTests.swift`
- Create: `Tests/LocalOCRCoreTests/OutputNamingTests.swift`
- Create: `Tests/LocalOCRCoreTests/FileHashingTests.swift`

**Interfaces:**
- Consumes: `LocalOCRError` from Task 1.
- Produces: `PageRange.parse(_:totalPages:) -> [Int]`, `OutputNaming.searchablePDFURL(for:fileExists:) -> URL`, and `FileHashing.sha256(of:) async throws -> String`.

- [ ] **Step 1: Write failing page-range tests**

```swift
@Test func parsesOneIndexedRanges() throws {
    #expect(try PageRange.parse(nil, totalPages: 5) == [0, 1, 2, 3, 4])
    #expect(try PageRange.parse("1-3,5", totalPages: 5) == [0, 1, 2, 4])
    #expect(try PageRange.parse("3,3,2", totalPages: 5) == [1, 2])
}

@Test func rejectsMalformedAndOutOfBoundsRanges() {
    #expect(throws: LocalOCRError.invalidPageSelection("3-1")) {
        try PageRange.parse("3-1", totalPages: 5)
    }
    #expect(throws: LocalOCRError.pageOutOfBounds(page: 6, total: 5)) {
        try PageRange.parse("6", totalPages: 5)
    }
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter PageRangeTests`

Expected: FAIL because `PageRange` does not exist.

- [ ] **Step 3: Implement the minimal parser**

Split on commas, trim whitespace, parse single integers or one hyphenated
inclusive range, reject empty tokens, descending ranges, non-integers, zero,
and values above `totalPages`; deduplicate and return zero-based indices sorted
ascending.

- [ ] **Step 4: Run page-range tests**

Run: `swift test --filter PageRangeTests`

Expected: PASS.

- [ ] **Step 5: Write failing output-name and hashing tests**

```swift
@Test func searchableOutputNeverOverwrites() {
    let source = URL(fileURLWithPath: "/tmp/report.pdf")
    let occupied: Set<String> = ["/tmp/report_searchable.pdf"]
    let output = OutputNaming.searchablePDFURL(for: source) {
        occupied.contains($0.path)
    }
    #expect(output.lastPathComponent == "report_searchable_2.pdf")
}

@Test func hashesWithoutLoadingWholeFile() async throws {
    let url = try FixtureFiles.write(bytes: Array(repeating: 0x61, count: 2_000_000))
    #expect(try await FileHashing.sha256(of: url) ==
        "bcf7f9d1b4311c3352e60502255ce09a6744df84e8f2c89f79c4b5d74933a95a")
}
```

- [ ] **Step 6: Implement collision-safe naming and streaming SHA-256**

Use `FileHandle.read(upToCount: 1_048_576)` and `CryptoKit.SHA256`. Default to
`<stem>_searchable.pdf`, then `<stem>_searchable_2.pdf`, incrementing until the
injected `fileExists` closure returns false.

- [ ] **Step 7: Run focused and full Swift tests**

Run: `swift test --filter OutputNamingTests && swift test --filter FileHashingTests && swift test`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LocalOCRCore Tests/LocalOCRCoreTests
git commit -m "feat: add page selection and file identity utilities"
```

---

### Task 3: PDF Inspection and Incremental Rasterization

**Files:**
- Create: `Sources/LocalOCRCore/PDFDocumentSource.swift`
- Create: `Tests/LocalOCRCoreTests/PDFDocumentSourceTests.swift`
- Create: `Tests/LocalOCRCoreTests/Fixtures/mixed.pdf`
- Create: `Tests/LocalOCRCoreTests/Fixtures/image-only.pdf`

**Interfaces:**
- Consumes: `PageInspection`, `PDFInspection`, and `LocalOCRError`.
- Produces:

```swift
public protocol PDFDocumentReading: Sendable {
    func inspect(_ url: URL) throws -> PDFInspection
    func nativeText(in url: URL, pageIndex: Int) throws -> String
    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage
}

public struct PDFDocumentSource: PDFDocumentReading {
    public static let minimumNativeCharacters = 20
}
```

- [ ] **Step 1: Generate public/synthetic PDF fixtures**

Add a deterministic fixture generator using only PyMuPDF. `mixed.pdf` contains
one page with 20+ characters of vector text and one rasterized text image.
`image-only.pdf` contains two rasterized pages and no native text layer.

- [ ] **Step 2: Write failing inspection tests**

```swift
@Test func inspectsMixedPDF() throws {
    let result = try PDFDocumentSource().inspect(Fixtures.mixedPDF)
    #expect(result.pages == 2)
    #expect(result.searchablePages == [1])
    #expect(result.ocrNeededPages == [2])
    #expect(result.fullySearchable == false)
}
```

Also test missing files, invalid PDFs, exactly 19 versus 20 trimmed
characters, and one-indexed values in the public inspection result.

- [ ] **Step 3: Run and verify failure**

Run: `swift test --filter PDFDocumentSourceTests`

Expected: FAIL because `PDFDocumentSource` does not exist.

- [ ] **Step 4: Implement PDF inspection**

Use `PDFDocument(url:)`, iterate `PDFPage.string`, trim whitespace, and compare
against `minimumNativeCharacters`. Return page details without invoking Vision.

- [ ] **Step 5: Add failing rasterization tests**

Assert that rasterizing page 0 at 250 DPI returns dimensions within one pixel
of `page.bounds(for: .mediaBox) * 250 / 72`, produces an RGB image, and throws
`.pageOutOfBounds` for an invalid page.

- [ ] **Step 6: Implement incremental rasterization**

Open the PDF only for the call, render one page into a `CGContext`, fill the
background white, transform the PDF media box into image coordinates, draw
the page, return the `CGImage`, and release the context before the next page.

- [ ] **Step 7: Run tests**

Run: `swift test --filter PDFDocumentSourceTests && swift test`

Expected: PASS with no fixture containing private data.

- [ ] **Step 8: Commit**

```bash
git add Sources/LocalOCRCore/PDFDocumentSource.swift Tests/LocalOCRCoreTests
git commit -m "feat: inspect and rasterize PDF pages"
```

---

### Task 4: Vision Recognition and Orientation Selection

**Files:**
- Create: `Sources/LocalOCRCore/VisionTextRecognizer.swift`
- Create: `Sources/LocalOCRCore/OrientationSelector.swift`
- Create: `Tests/LocalOCRCoreTests/VisionTextRecognizerTests.swift`
- Create: `Tests/LocalOCRCoreTests/OrientationSelectorTests.swift`
- Create: `Tests/LocalOCRCoreTests/Fixtures/upright-text.png`
- Create: `Tests/LocalOCRCoreTests/Fixtures/sideways-text.png`

**Interfaces:**
- Consumes: `RecognitionSettings`, `TextLine`, and `LocalOCRError`.
- Produces:

```swift
public struct RecognitionCandidate: Sendable, Equatable {
    public let orientation: CGImagePropertyOrientation
    public let lines: [TextLine]
    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public protocol TextRecognizing: Sendable {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate
}

public struct OrientationSelector {
    public func best(
        image: CGImage,
        settings: RecognitionSettings,
        recognizer: any TextRecognizing
    ) async throws -> RecognitionCandidate
}
```

- [ ] **Step 1: Write failing Vision adapter tests**

Test an upright synthetic image containing `LOCAL OCR TEST 123`, asserting:
non-empty lines, accurate recognition level behavior, confidence in `0...1`,
normalized bounding boxes, and requested recognition languages passed through.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter VisionTextRecognizerTests`

Expected: FAIL because `VisionTextRecognizer` does not exist.

- [ ] **Step 3: Implement the Vision adapter**

Use `VNRecognizeTextRequest`, `.accurate`, the settings'
`usesLanguageCorrection`, and optional `recognitionLanguages`. For each
top candidate, preserve Vision's normalized lower-left-origin bounding box.
Wrap request completion in a checked continuation and map Vision failures to
`.recognitionFailed`.

- [ ] **Step 4: Run Vision tests**

Run: `swift test --filter VisionTextRecognizerTests`

Expected: PASS on macOS 14+.

- [ ] **Step 5: Write failing orientation tests with a fake recognizer**

```swift
@Test func retriesWhenUprightScoreIsWeak() async throws {
    let fake = FakeRecognizer(results: [
        .up: candidate(.up, text: "1"),
        .right: candidate(.right, text: "LOCAL OCR TEST 123")
    ])
    let result = try await OrientationSelector().best(
        image: Fixtures.onePixelImage,
        settings: .init(),
        recognizer: fake
    )
    #expect(result.orientation == .right)
}
```

Also assert that a strong upright candidate avoids extra recognition calls.

- [ ] **Step 6: Implement deterministic scoring**

Score each candidate as:

```swift
let nonWhitespace = candidate.text.filter { !$0.isWhitespace }.count
let meanConfidence = candidate.lines.isEmpty
    ? 0
    : candidate.lines.map(\.confidence).reduce(0, +) / Float(candidate.lines.count)
let score = Double(nonWhitespace) * (0.5 + Double(meanConfidence))
```

Accept upright without retries when it has at least 12 non-whitespace
characters and mean confidence at least `0.55`. Otherwise test `.right`,
`.down`, and `.left`, choosing the highest score with `.up` winning ties.

- [ ] **Step 7: Validate with the real sideways fixture**

Run: `swift test --filter OrientationSelectorTests && swift test`

Expected: The sideways fixture chooses a non-up orientation and all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LocalOCRCore Tests/LocalOCRCoreTests
git commit -m "feat: recognize text with rotation recovery"
```

---

### Task 5: Actor-Backed Content-Addressed Cache

**Files:**
- Create: `Sources/LocalOCRCore/OCRCache.swift`
- Create: `Tests/LocalOCRCoreTests/OCRCacheTests.swift`

**Interfaces:**
- Consumes: `RecognitionSettings` and `RecognitionCandidate`.
- Produces:

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
    public func store(_ value: RecognitionCandidate, for key: OCRCacheKey) throws
    public func removeAll() throws
}
```

- [ ] **Step 1: Write failing cache tests**

Test round-trip persistence across two `OCRCache` instances, distinct entries
for DPI/language/force settings, corrupt entry treated as a miss and removed,
atomic concurrent writes to the same key, and `removeAll`.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter OCRCacheTests`

Expected: FAIL because `OCRCache` does not exist.

- [ ] **Step 3: Implement stable keys and atomic storage**

Encode the key as sorted-key JSON, hash that JSON with SHA-256, shard files by
the first two hex characters, encode candidates as JSON, write to a unique
temporary sibling, then use `FileManager.replaceItemAt` or move when no
destination exists. Create directories with user-only permissions.

- [ ] **Step 4: Handle corrupt and stale entries**

On decoding failure, remove the entry and return `nil`. Changing
`compatibilityVersion` naturally creates a different key; do not scan or
rewrite prior versions during lookup.

- [ ] **Step 5: Run cache and full tests**

Run: `swift test --filter OCRCacheTests && swift test`

Expected: PASS, including concurrent test repetitions.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocalOCRCore/OCRCache.swift Tests/LocalOCRCoreTests/OCRCacheTests.swift
git commit -m "feat: add resumable OCR page cache"
```

---

### Task 6: Incremental OCR Orchestration, Progress, Cancellation, and Partial Results

**Files:**
- Create: `Sources/LocalOCRCore/OCRProcessor.swift`
- Create: `Tests/LocalOCRCoreTests/OCRProcessorTests.swift`

**Interfaces:**
- Consumes: `PDFDocumentReading`, `TextRecognizing`, `OrientationSelector`,
  `OCRCache`, `FileHashing`, `PageRange`, and Task 1 models.
- Produces:

```swift
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

- [ ] **Step 1: Write failing orchestration tests with fakes**

Cover these exact behaviors:

- Native-text pages return `.existingText` and never call Vision.
- `forceOCR` recognizes native-text pages.
- Only selected pages are processed.
- Cache hits skip rasterization and recognition.
- A failing page appears in `failedPages` while later pages complete.
- Blank successful recognition appears in `emptyOCRPages`.
- Non-up orientation appears in `rotatedOCRPages`.
- Progress is ordered: `.inspecting`, page events, `.completed`.
- Cancellation between pages throws `.cancelled` after preserving prior cache
  writes.
- The fake rasterizer never has more than one live image, enforcing bounded
  page-at-a-time behavior.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter OCRProcessorTests`

Expected: FAIL because `OCRProcessor` does not exist.

- [ ] **Step 3: Implement the page loop**

Hash and inspect the source, parse page selection, emit `.inspecting`, then for
each selected page:

```swift
try Task.checkCancellation()
progress(.recognizing(page: pageIndex + 1, total: selected.count))
```

Return native text when eligible. Otherwise look up the page cache, rasterize
and recognize on a miss, store a successful candidate, and append the
corresponding result. Catch page-scoped errors, append the one-indexed page to
`failedPages`, and continue. Convert `CancellationError` only to
`LocalOCRError.cancelled`; never record cancellation as a failed page.

- [ ] **Step 4: Ensure deterministic results**

Keep pages and failure arrays in ascending source-page order. Join line text
with `\n`. Include lines on every Vision result and an empty `lines` array for
native text.

- [ ] **Step 5: Run focused and full tests**

Run: `swift test --filter OCRProcessorTests && swift test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocalOCRCore/OCRProcessor.swift Tests/LocalOCRCoreTests/OCRProcessorTests.swift
git commit -m "feat: orchestrate incremental OCR processing"
```

---

### Task 7: Searchable-PDF Writer with Atomic Validation

**Files:**
- Create: `Sources/LocalOCRCore/SearchablePDFWriter.swift`
- Create: `Tests/LocalOCRCoreTests/SearchablePDFWriterTests.swift`
- Create: `Tests/LocalOCRCoreTests/Fixtures/overlay-source.pdf`

**Interfaces:**
- Consumes: `PageResult`, `TextLine`, `OutputNaming`, `LocalOCRError`, and
  `PDFDocumentReading`.
- Produces:

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
```

- [ ] **Step 1: Write failing searchable-PDF tests**

Test that:

- Page count and media-box dimensions equal the source.
- Rendered pixels sampled from the output match the source within a defined
  tolerance, proving the original appearance remains intact.
- `PDFPage.string` contains recognized text after output.
- Existing native-text pages are copied without a duplicate overlay.
- A result missing one page reports that page and `isComplete == false`.
- The source remains byte-for-byte unchanged.
- An invalid destination does not leave a partial final file.
- Output is reopened and validated before atomic replacement.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter SearchablePDFWriterTests`

Expected: FAIL because `SearchablePDFWriter` does not exist.

- [ ] **Step 3: Implement page-preserving PDF output**

Create a temporary PDF in the destination directory. For each source page,
draw the original PDF page into a Core Graphics PDF context. For Vision OCR
lines only, convert normalized lower-left-origin boxes into page coordinates,
fit a Helvetica font to the bounding width, set text rendering mode to
invisible (`.invisible`), and draw the line. Do not add overlays for
`.existingText` pages.

- [ ] **Step 4: Validate and atomically commit**

Close the context, reopen the temporary PDF with `PDFDocument`, verify page
count and that each successful OCR page exposes non-empty text, then move or
replace the destination atomically. On any error, remove only the temporary
file and leave source/destination unchanged.

- [ ] **Step 5: Run output tests and visually inspect the fixture**

Run: `swift test --filter SearchablePDFWriterTests && swift test`

Expected: PASS.

Open the generated test artifact in Preview, compare it beside the source,
search for `LOCAL OCR OVERLAY`, and verify no visible text or page shift.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocalOCRCore/SearchablePDFWriter.swift Tests/LocalOCRCoreTests
git commit -m "feat: create validated searchable PDFs"
```

---

### Task 8: Cross-Implementation Comparison, Privacy Audit, and Engine Documentation

**Files:**
- Create: `scripts/compare-engine-contracts.py`
- Create: `Tests/LocalOCRCoreTests/EngineIntegrationTests.swift`
- Create: `docs/engine-api.md`
- Modify: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: All prior engine APIs and Python contract JSON.
- Produces: Repeatable Swift-versus-Python comparison report and documented
  engine integration contract for later CLI/MCP/app plans.

- [ ] **Step 1: Add a Swift integration fixture exporter**

Write a test helper that processes the same synthetic fixtures as Python and
writes normalized JSON with `source_path` and `source_sha256` replaced by
`<fixture>` and `<sha256>`. Preserve the Python field names:
`source_path`, `source_sha256`, `pages`, `failed_pages`, `empty_ocr_pages`,
and `rotated_ocr_pages`.

- [ ] **Step 2: Write the comparison script**

`scripts/compare-engine-contracts.py` loads Python and Swift JSON, checks exact
structure and page/method/failure fields, then reports recognition text with a
normalized Levenshtein similarity. Require `>= 0.95` for synthetic printed
fixtures while reporting confidence and orientation differences.

- [ ] **Step 3: Run cross-implementation verification**

Run:

```bash
.venv/bin/python scripts/generate-contract-fixtures.py
swift test
.venv/bin/python scripts/compare-engine-contracts.py
```

Expected: Python tests PASS, Swift tests PASS, structural contract matches,
and printed-text fixture similarity is at least `0.95`.

- [ ] **Step 4: Audit the package for network and private-data paths**

Run:

```bash
rg -n 'URLSession|Network\\.|NWConnection|Telemetry|Analytics|Sentry|http://|https://' Sources Tests
rg -n '/Users/|scottray|Scott Ray|Ray Consulting' Sources Tests scripts
```

Expected: No network APIs or hard-coded private paths in the engine. Any
`https://` occurrence must be documentation text outside `Sources`.

- [ ] **Step 5: Run clean-build and strict-concurrency verification**

Run:

```bash
swift package clean
swift build
swift test
.venv/bin/python -m pytest -v
```

Expected: Clean Swift build succeeds without concurrency warnings; all Swift
and Python tests PASS.

- [ ] **Step 6: Document the engine API**

In `docs/engine-api.md`, document:

- Supported inputs and outputs
- The exact public types and protocols created in this plan
- Page numbering and native-text threshold
- Progress and cancellation semantics
- Cache identity and clearing behavior
- Partial-failure guarantees
- Searchable-PDF coordinate behavior and numeric-accuracy warning
- A minimal Swift example that constructs `OCRProcessor` and processes one PDF

Update `README.md` with a “Native Swift migration” section that identifies the
Python code as the behavioral reference and links to the approved design,
engine API, and this plan.

- [ ] **Step 7: Ignore generated artifacts**

Add `.build/`, Swift test artifacts, generated comparison output, and local OCR
caches to `.gitignore`. Do not ignore committed synthetic fixtures or expected
contract JSON.

- [ ] **Step 8: Commit**

```bash
git add README.md .gitignore docs scripts Tests
git commit -m "docs: verify and document native OCR engine"
```

- [ ] **Step 9: Record the engine milestone**

Run:

```bash
git status --short
git log --oneline --decorate -10
swift test
.venv/bin/python -m pytest -q
```

Expected: Clean working tree, all tests PASS, and eight independently
reviewable engine commits after the imported baseline.

---

## Follow-On Plans

After this engine plan passes review and implementation:

1. **CLI and MCP plan:** Add native executables, preserve the six existing MCP
   tools, add structured contract tests, package the standalone open-source
   distribution, and document manual client setup.
2. **Workflow Studio app plan:** Build the sandboxed SwiftUI library, Inbox,
   Completed, History, queue persistence, bookmarks, settings, output actions,
   and free-tier experience.
3. **Commercial automation plan:** Add licensing boundaries, watched folders,
   presets, large-queue controls, and previewed Codex/Claude configuration.
4. **Release plan:** Add app signing, notarization, updater, clean-machine
   installation testing, privacy verification, licensing material, and public
   release documentation.

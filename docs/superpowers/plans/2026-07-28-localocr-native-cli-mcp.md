# LocalOCR Native CLI and MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship native `localocr` and `localocr-mcp` executables that expose the completed Swift OCR engine, preserve the six existing Python MCP tool contracts, and are ready to embed in a directly distributed macOS app without Python, Homebrew, or network services.

**Architecture:** Add a reusable `LocalOCRService` actor above `LocalOCRCore`, then place thin CLI and MCP adapters above that service. Command parsing lives in `LocalOCRCommandKit`; MCP schemas and dispatch live in `LocalOCRMCP`; two minimal executable targets own process startup. The Python implementation remains the behavioral oracle until subprocess contract tests prove the native server compatible.

**Tech Stack:** Swift 6, Swift Package Manager, macOS 14+, Apple Vision, PDFKit, ImageIO, UniformTypeIdentifiers, `swift-argument-parser` 1.8.2, official `modelcontextprotocol/swift-sdk` 0.12.1, XCTest/Swift Testing, and the existing Python MCP test client for executable-level compatibility tests.

## Global Constraints

- macOS 14.0 is the minimum deployment target; all local Swift targets use Swift 6 strict concurrency.
- Pin `swift-argument-parser` to exactly `1.8.2` and `modelcontextprotocol/swift-sdk` to exactly `0.12.1`; commit `Package.resolved`.
- The MCP server uses stdio only. It does not open a port, make network requests, or start an HTTP transport.
- Standard output from `localocr-mcp` is protocol-only. Diagnostics go to standard error.
- Document contents, OCR text, filenames, paths, thumbnails, and hashes never cross a network boundary.
- Original inputs remain immutable. Searchable PDFs are new files and never silently overwrite an input or existing output.
- Retain these MCP tool names and parameter meanings: `get_pdf_page_count`, `inspect_pdf`, `ocr_pdf`, `ocr_pdf_batch`, `ocr_image`, and `make_searchable_pdf`.
- MCP responses retain the Python implementation's existing keys and value meanings. New fields must be additive.
- `include_lines=false` omits the `lines` key from each serialized page rather than emitting an empty array.
- PDF page numbers and page selections are one-indexed. Default rendering remains 250 DPI.
- Image inputs are any local file that ImageIO can decode into a `CGImage` and Vision can recognize; unsupported or corrupt images fail clearly.
- The CLI and MCP adapter call the same `LocalOCRService`; neither duplicates OCR, PDF inspection, caching, or searchable-PDF logic.
- A failure in one page or one batch item does not terminate the server or discard unrelated successful results.
- The default cache is `~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; `LOCALOCR_CACHE_DIR` overrides it for tests and advanced users.
- The native MCP server must not modify Codex, Claude, or another client's configuration. Connection management belongs to the later Mac app plan.
- Do not remove the Python implementation until every native compatibility test passes and the Mac app embeds the native executable.
- Apple signing, notarization, DMG creation, Sparkle, licensing, and the SwiftUI app are outside this plan. This plan produces release binaries ready for the app bundle and release pipeline.

---

## Planned File Structure

```text
Package.swift
Package.resolved
Sources/
  LocalOCRCore/                         Existing OCR engine
  LocalOCRService/
    LocalOCRServing.swift               Injectable shared service protocol
    LocalOCRService.swift               Actor façade over LocalOCRCore
    LocalOCRRuntime.swift               Version and cache-path policy
    Requests.swift                      Shared operation requests
    Responses.swift                     Stable wire DTOs
    ResponseEncoding.swift              snake_case JSON and optional fields
    ImageDocumentSource.swift           ImageIO decoding and validation
  LocalOCRCommandKit/
    CLIApplication.swift                Injectable command runner and exit codes
    CommandOutput.swift                 stdout/stderr abstraction
    Commands/
      PageCountCommand.swift
      InspectCommand.swift
      OCRCommand.swift
      BatchCommand.swift
      ImageCommand.swift
      SearchableCommand.swift
  LocalOCRCLIExecutable/
    main.swift                          `localocr` entry point
  LocalOCRMCP/
    MCPToolCatalog.swift                Six schemas and annotations
    MCPArgumentDecoder.swift            MCP.Value to typed request conversion
    MCPToolDispatcher.swift             Service calls and stable results
    MCPServerRunner.swift               Official SDK handler registration
  LocalOCRMCPExecutable/
    main.swift                          `localocr-mcp` entry point
tests/
  LocalOCRServiceTests/
  LocalOCRCommandKitTests/
  LocalOCRMCPTests/
  contract/
    expected/
      mcp_tool_catalog.json
      inspect_pdf.json
      ocr_pdf.json
      ocr_pdf_lines.json
      ocr_pdf_batch.json
      make_searchable_pdf.json
    test_native_mcp_server.py
    test_native_python_compatibility.py
scripts/
  build-native-tools.sh
  smoke-native-tools.sh
docs/
  cli.md
  mcp.md
```

The executable targets contain only process startup. Reusable behavior stays in
library targets so it can be tested in-process and reused by the Mac app.

---

### Task 1: Expand the Swift Package Graph and Freeze Wire DTOs

**Files:**
- Modify: `Package.swift`
- Create: `Package.resolved`
- Create: `Sources/LocalOCRService/LocalOCRRuntime.swift`
- Create: `Sources/LocalOCRService/Requests.swift`
- Create: `Sources/LocalOCRService/Responses.swift`
- Create: `Sources/LocalOCRService/ResponseEncoding.swift`
- Create: `tests/LocalOCRServiceTests/ResponseEncodingTests.swift`

**Interfaces:**
- Produces library product `LocalOCRService`.
- Produces executable products `localocr` and `localocr-mcp`.
- Defines stable request DTOs for six operations and stable `snake_case` response DTOs matching the Python server.
- Exposes `LocalOCRRuntime.version = "0.2.0"` and cache-path resolution.

- [ ] **Step 1: Add a failing DTO encoding test**

Create `ResponseEncodingTests.swift` and assert exact JSON, including omission
of line geometry when it was not requested:

```swift
@Test func ocrResponseOmitsLinesUnlessRequested() throws {
    let response = PDFOCRResponse.fixture(includeLines: false)
    let object = try #require(
        JSONSerialization.jsonObject(with: ResponseEncoding.encode(response))
            as? [String: Any]
    )
    let page = try #require((object["pages"] as? [[String: Any]])?.first)

    #expect(object["source_path"] as? String == "/tmp/input.pdf")
    #expect(object["failed_pages"] as? [Int] == [])
    #expect(page["method"] as? String == "existing_text")
    #expect(page["lines"] == nil)
}
```

- [ ] **Step 2: Run the service tests and verify failure**

Run: `swift test --filter LocalOCRServiceTests`

Expected: FAIL because the target and DTOs do not exist.

- [ ] **Step 3: Add exact package dependencies and targets**

Update `Package.swift` to contain:

```swift
dependencies: [
    .package(
        url: "https://github.com/apple/swift-argument-parser",
        exact: "1.8.2"
    ),
    .package(
        url: "https://github.com/modelcontextprotocol/swift-sdk",
        exact: "0.12.1"
    )
],
products: [
    .library(name: "LocalOCRCore", targets: ["LocalOCRCore"]),
    .library(name: "LocalOCRService", targets: ["LocalOCRService"]),
    .executable(name: "localocr", targets: ["LocalOCRCLIExecutable"]),
    .executable(name: "localocr-mcp", targets: ["LocalOCRMCPExecutable"])
]
```

Add library targets `LocalOCRService`, `LocalOCRCommandKit`, and `LocalOCRMCP`;
executable targets `LocalOCRCLIExecutable` and `LocalOCRMCPExecutable`; and a
test target for each library. Apply
`.enableUpcomingFeature("StrictConcurrency")` to every local target.
`LocalOCRCommandKit` depends on `LocalOCRService` and the
`ArgumentParser` product. `LocalOCRMCP` depends on `LocalOCRService` and the
`MCP` product. Because this repository already uses a lowercase `tests`
directory, give each new test target an explicit path:
`tests/LocalOCRServiceTests`, `tests/LocalOCRCommandKitTests`, and
`tests/LocalOCRMCPTests`.

- [ ] **Step 4: Define runtime policy**

Implement these exact public members:

```swift
public enum LocalOCRRuntime {
    public static let version = "0.2.0"

    public static func cacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL
}
```

If `LOCALOCR_CACHE_DIR` is nonempty, expand `~`, standardize it, and return it.
Otherwise use the user-domain caches directory and append
`com.rayconsulting.localocr/ocr-v1`. Create the directory only when a service
actually enables caching.

- [ ] **Step 5: Define typed requests**

Create immutable `Sendable` request types:

```swift
public struct PDFOCRRequest: Sendable, Equatable {
    public let fileURL: URL
    public let pageRange: String?
    public let dpi: Int
    public let forceOCR: Bool
    public let includeLines: Bool
    public let usesCache: Bool
}

public struct BatchOCRRequest: Sendable, Equatable {
    public let fileURLs: [URL]
    public let pageRange: String?
    public let dpi: Int
    public let forceOCR: Bool
    public let includeLines: Bool
    public let usesCache: Bool
}

public struct ImageOCRRequest: Sendable, Equatable {
    public let fileURL: URL
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool
}

public struct SearchablePDFRequest: Sendable, Equatable {
    public let fileURL: URL
    public let outputURL: URL?
    public let dpi: Int
    public let forceOCR: Bool
    public let usesCache: Bool
}
```

Validate `dpi` in `72...600`, reject an empty batch, and delegate one-indexed
page-range validation to `LocalOCRCore.PageRange`.

- [ ] **Step 6: Define stable response DTOs**

All response types conform to `Sendable`, `Codable`, and `Equatable`.
`ResponseEncoding.encoder` uses `.convertToSnakeCase` and sorted keys.

```swift
public struct PageCountResponse: Sendable, Codable, Equatable {
    public let pages: Int
}

public struct InspectPDFResponse: Sendable, Codable, Equatable {
    public let sourcePath: String
    public let sourceSHA256: String
    public let pages: Int
    public let searchablePages: Int
    public let ocrNeededPages: Int
    public let characters: Int
    public let fullySearchable: Bool
    public let pageDetails: [PageInspectionResponse]
}

public struct PDFOCRResponse: Sendable, Codable, Equatable {
    public let sourcePath: String
    public let sourceSHA256: String
    public let pages: [OCRPageResponse]
    public let failedPages: [Int]
    public let emptyOCRPages: [Int]
    public let rotatedOCRPages: [RotatedPageResponse]
}

public struct BatchOCRResponse: Sendable, Codable, Equatable {
    public let processed: Int
    public let succeeded: Int
    public let failed: Int
    public let results: [BatchItemResponse]
}

public struct ImageOCRResponse: Sendable, Codable, Equatable {
    public let text: String
}

public struct SearchablePDFResponse: Sendable, Codable, Equatable {
    public let outputPath: String
    public let failedPages: [Int]
}
```

`OCRPageResponse` uses custom `encode(to:)` so `lines` is encoded only when
its optional value is non-nil. Preserve the published MCP line shape by
flattening each engine bounding box into sibling `x`, `y`, `width`, and
`height` fields alongside `text` and `confidence`. Do not expose the engine's
per-page `orientation` field in `pages`; expose non-upright orientation only
through `rotated_ocr_pages`. Encode those orientations as stable strings:
`up`, `right`, `down`, `left`, and their mirrored variants.

- [ ] **Step 7: Resolve dependencies and run tests**

Run:

```bash
swift package resolve
swift test --filter LocalOCRServiceTests
```

Expected: `Package.resolved` pins the two requested versions and all DTO
encoding tests PASS.

- [ ] **Step 8: Commit the package and wire contract**

```bash
git add Package.swift Package.resolved Sources/LocalOCRService tests/LocalOCRServiceTests
git commit -m "feat: define native interface wire contracts"
```

---

### Task 2: Build the Shared Service and Image Recognition Path

**Files:**
- Create: `Sources/LocalOCRService/LocalOCRServing.swift`
- Create: `Sources/LocalOCRService/LocalOCRService.swift`
- Create: `Sources/LocalOCRService/ImageDocumentSource.swift`
- Create: `tests/LocalOCRServiceTests/LocalOCRServiceTests.swift`
- Create: `tests/LocalOCRServiceTests/ImageDocumentSourceTests.swift`
- Copy: `tests/LocalOCRCoreTests/Fixtures/upright-text.png` to `tests/LocalOCRServiceTests/Fixtures/sample.png`
- Create: `tests/LocalOCRServiceTests/Fixtures/corrupt-image.png`

**Interfaces:**
- Consumes `OCRProcessor`, `PDFDocumentSource`, `VisionTextRecognizer`,
  `OCRCache`, `SearchablePDFWriter`, and output naming from `LocalOCRCore`.
- Produces one injectable `LocalOCRServing` protocol used by both adapters.
- Image recognition uses ImageIO decoding and the existing Vision recognizer;
  it adds no third-party converter.

- [ ] **Step 1: Write failing service orchestration tests**

Cover page count, inspection mapping, PDF OCR mapping, sequential batch
isolation, image OCR, searchable output, cache disabled, and cancellation:

```swift
@Test func batchPreservesSuccessWhenAnotherInputFails() async throws {
    let service = LocalOCRService.fixture(
        outcomes: [
            "/tmp/good.pdf": .success(.ocrFixture),
            "/tmp/bad.pdf": .failure(.invalidPDF("/tmp/bad.pdf"))
        ]
    )

    let result = await service.ocrPDFBatch(.fixture(
        fileURLs: [URL(fileURLWithPath: "/tmp/good.pdf"),
                   URL(fileURLWithPath: "/tmp/bad.pdf")]
    ))

    #expect(result.processed == 2)
    #expect(result.succeeded == 1)
    #expect(result.failed == 1)
    #expect(result.results.count == 2)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter LocalOCRServiceTests`

Expected: FAIL because `LocalOCRServing` and `LocalOCRService` do not exist.

- [ ] **Step 3: Define the shared service protocol**

Use this interface:

```swift
public protocol LocalOCRServing: Sendable {
    func pageCount(at fileURL: URL) async throws -> PageCountResponse
    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse
    func ocrPDF(
        _ request: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse
    func ocrPDFBatch(
        _ request: BatchOCRRequest,
        progress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse
    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse
    func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse
}
```

Provide overloads with no-op progress closures. Define `BatchProgress` as the
current one-indexed item, total item count, source path, and nested
`OCRProgress`.

- [ ] **Step 4: Implement local-file validation and service mapping**

`LocalOCRService` is an actor. Reject non-file URLs and missing, unreadable,
directory, or wrong-type inputs before creating engine dependencies. Map
engine results to wire DTOs without changing source page order.

For batches, process files in supplied order with concurrency one to preserve
bounded memory. Preserve the legacy flat item shape. A success contains all
top-level `PDFOCRResponse` keys plus `"status": "ok"`; it does not nest the
OCR response under a `result` key. Catch each item error and append:

```swift
public enum BatchItemResponse: Sendable, Equatable {
    case success(PDFOCRResponse)
    case failure(sourcePath: String, message: String)
}
```

Give this enum custom `Codable` handling. Failures encode exactly
`source_path`, `"status": "error"`, and a human-readable string `error`, while
successes flatten the PDF result and add `"status": "ok"`.

- [ ] **Step 5: Implement ImageIO input decoding**

Use `CGImageSourceCreateWithURL`, `CGImageSourceGetType`, and
`CGImageSourceCreateImageAtIndex`. Reject an absent type, zero frames, or a
failed `CGImage` decode as `LocalOCRError.unsupportedFormat` or
`LocalOCRError.imageDecodeFailed`. Feed the decoded `CGImage` to the existing
Vision recognizer with the request language settings. Join recognized lines
in reading order with `\n`.

- [ ] **Step 6: Implement searchable-PDF orchestration**

Resolve a nil output with the engine's collision-safe output naming. Run PDF
OCR, pass successful page results to `SearchablePDFWriter`, validate the
created PDF by reopening it, and return the union of OCR and writer failures.
Write through a sibling temporary file and atomically move it only after
validation. Never overwrite the source or an existing destination.

- [ ] **Step 7: Make cancellation and cache selection explicit**

Call `Task.checkCancellation()` before inspection, before every source item,
and before searchable-PDF assembly. With `usesCache=false`, construct the
processor without an `OCRCache`; otherwise use `LocalOCRRuntime.cacheURL()`.
Preserve completed cache entries when a task is cancelled.

- [ ] **Step 8: Run the service and engine suites**

Run:

```bash
swift test --filter LocalOCRServiceTests
swift test --filter LocalOCRCoreTests
```

Expected: All service tests and the existing 75 core tests PASS.

- [ ] **Step 9: Commit the shared service**

```bash
git add Sources/LocalOCRService tests/LocalOCRServiceTests
git commit -m "feat: add shared local OCR service"
```

---

### Task 3: Implement the Native `localocr` CLI

**Files:**
- Create: `Sources/LocalOCRCommandKit/CLIApplication.swift`
- Create: `Sources/LocalOCRCommandKit/CommandOutput.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/PageCountCommand.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/InspectCommand.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/OCRCommand.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/BatchCommand.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/ImageCommand.swift`
- Create: `Sources/LocalOCRCommandKit/Commands/SearchableCommand.swift`
- Create: `Sources/LocalOCRCLIExecutable/main.swift`
- Create: `tests/LocalOCRCommandKitTests/CLIApplicationTests.swift`
- Create: `tests/LocalOCRCommandKitTests/CLITestSupport.swift`

**Interfaces:**
- Produces commands `page-count`, `inspect`, `ocr`, `batch`, `image`, and
  `searchable`.
- Machine-readable output uses the same response encoder as MCP.
- Exit codes are stable: `0` success, `1` operation failure, `2` invalid
  arguments, `3` partial result, and `4` cancellation.

- [ ] **Step 1: Add failing CLI contract tests**

Use a fake `LocalOCRServing` and in-memory stdout/stderr sinks:

```swift
@Test func inspectJSONUsesWireContractAndKeepsStderrEmpty() async {
    let harness = CLIHarness(service: .fixture(inspect: .fixture))
    let status = await harness.run(["inspect", "/tmp/input.pdf", "--json"])

    #expect(status == 0)
    #expect(harness.stdoutJSON()["fully_searchable"] as? Bool == false)
    #expect(harness.stderr == "")
}

@Test func partialOCRReturnsThree() async {
    let harness = CLIHarness(service: .fixture(ocr: .partialFixture))
    #expect(await harness.run(["ocr", "/tmp/input.pdf", "--json"]) == 3)
}
```

Also test every command's help, default DPI, page range, force OCR, cache
bypass, line detail, language list, output path, malformed arguments,
operation errors, and cancellation.

- [ ] **Step 2: Run CLI tests and verify failure**

Run: `swift test --filter LocalOCRCommandKitTests`

Expected: FAIL because the CLI library does not exist.

- [ ] **Step 3: Define command IO and application runner**

```swift
public struct CommandOutput: Sendable {
    public let stdout: @Sendable (String) -> Void
    public let stderr: @Sendable (String) -> Void
}

public struct CLIApplication: Sendable {
    public init(service: any LocalOCRServing, output: CommandOutput)
    public func run(arguments: [String]) async -> Int32
}
```

The executable passes `Array(CommandLine.arguments.dropFirst())` and writes
through `FileHandle.standardOutput` and `.standardError`. It calls
`Foundation.exit(status)` with the returned code.

- [ ] **Step 4: Add the exact command surface**

```text
localocr page-count <file> [--json]
localocr inspect <file> [--json]
localocr ocr <file> [--pages <spec>] [--dpi <72...600>]
             [--force-ocr] [--detail] [--no-cache] [--json]
localocr batch <files...> [--pages <spec>] [--dpi <72...600>]
               [--force-ocr] [--detail] [--no-cache] [--json]
localocr image <file> [--language <bcp47>]...
               [--no-language-correction] [--json]
localocr searchable <file> [--output <file>] [--dpi <72...600>]
                    [--force-ocr] [--no-cache] [--json]
```

`--detail` maps to `includeLines=true`. Without `--json`, OCR prints page text
with `--- Page N ---` boundaries, image prints plain recognized text,
inspection prints a compact human summary, and searchable output prints its
new path. Batch text output prints one source heading per result.

- [ ] **Step 5: Enforce stdout/stderr and exit-code behavior**

Successful requested data goes to stdout. Progress and errors go to stderr.
JSON mode emits exactly one complete JSON value followed by a newline.
Return `3` if PDF OCR has failed pages, searchable output has failed pages, or
a batch has failures. Map `CancellationError` to `4`; ArgumentParser validation
to `2`; all other service errors to `1`.

- [ ] **Step 6: Add the minimal executable**

Use `AsyncParsableCommand` only to describe and validate syntax. Route the
parsed command through `CLIApplication` so tests do not terminate their
process. Set the command name to `localocr` and version from
`LocalOCRRuntime.version`.

- [ ] **Step 7: Run unit and executable smoke tests**

Run:

```bash
swift test --filter LocalOCRCommandKitTests
swift build --product localocr
.build/debug/localocr --version
.build/debug/localocr inspect tests/LocalOCRCoreTests/Fixtures/mixed.pdf --json
```

Expected: Tests PASS; version is `0.2.0`; inspection prints one valid JSON
object and exits `0`.

- [ ] **Step 8: Commit the CLI**

```bash
git add Sources/LocalOCRCommandKit Sources/LocalOCRCLIExecutable tests/LocalOCRCommandKitTests
git commit -m "feat: add native localocr command line interface"
```

---

### Task 4: Define and Test the Six MCP Tools Independently of Transport

**Files:**
- Create: `Sources/LocalOCRMCP/MCPToolCatalog.swift`
- Create: `Sources/LocalOCRMCP/MCPArgumentDecoder.swift`
- Create: `Sources/LocalOCRMCP/MCPToolDispatcher.swift`
- Create: `tests/LocalOCRMCPTests/MCPToolCatalogTests.swift`
- Create: `tests/LocalOCRMCPTests/MCPArgumentDecoderTests.swift`
- Create: `tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift`
- Create: `tests/contract/expected/mcp_tool_catalog.json`

**Interfaces:**
- Produces six official SDK `Tool` values with JSON Schema inputs.
- Produces `CallTool.Result` values with JSON text plus matching
  `structuredContent`.
- Uses injectable `LocalOCRServing`; transport is not involved in these tests.

- [ ] **Step 1: Add a failing exact catalog snapshot test**

Assert sorted tool names are exactly:

```swift
[
    "get_pdf_page_count",
    "inspect_pdf",
    "make_searchable_pdf",
    "ocr_image",
    "ocr_pdf",
    "ocr_pdf_batch"
]
```

Serialize each name, description, input schema, output schema, and annotations
to `tests/contract/expected/mcp_tool_catalog.json`. Fail on a missing required
field or accidental tool rename.

- [ ] **Step 2: Run MCP library tests and verify failure**

Run: `swift test --filter LocalOCRMCPTests`

Expected: FAIL because the tool catalog does not exist.

- [ ] **Step 3: Implement exact input schemas**

Use `MCP.Value.object` schemas:

| Tool | Required | Optional defaults |
|---|---|---|
| `get_pdf_page_count` | `file_path: string` | none |
| `inspect_pdf` | `file_path: string` | none |
| `ocr_pdf` | `file_path: string` | `page_range: string`, `dpi: 250`, `force_ocr: false`, `include_lines: false` |
| `ocr_pdf_batch` | `file_paths: string[]` | same PDF options |
| `ocr_image` | `file_path: string` | none |
| `make_searchable_pdf` | `file_path: string` | `output_path: string`, `dpi: 250`, `force_ocr: false` |

Set `additionalProperties` to false, `dpi` minimum 72 and maximum 600, and
`file_paths.minItems` to 1. Describe paths as local absolute or
working-directory-relative filesystem paths.

- [ ] **Step 4: Add output schemas and annotations**

`get_pdf_page_count` returns an integer to retain legacy semantics.
`ocr_image` returns a string. Do not attach an object `outputSchema` to those
two scalar tools. Other tools return their response object schema.
The first five tools use annotations:

```swift
Tool.Annotations(
    title: nil,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
)
```

`make_searchable_pdf` is additive but writes a new file, so set
`readOnlyHint=false`, `destructiveHint=false`, `idempotentHint=false`, and
`openWorldHint=false`.

- [ ] **Step 5: Implement strict MCP argument decoding**

Resolve relative paths against an injected current directory. Reject empty
paths, non-string values, unknown keys, non-integral DPI, and values outside
the documented range. Use request defaults only when the key is absent.
Convert decoding failures to:

```json
{
  "error": {
    "code": "invalid_arguments",
    "message": "dpi must be an integer from 72 through 600"
  }
}
```

- [ ] **Step 6: Implement service dispatch and result conversion**

Switch exhaustively on all six names. For successful object responses, return
the canonical JSON string as text content and the same object as
`structuredContent`. For the two legacy scalar tools, return scalar text
content and omit `structuredContent`; this avoids changing the observable
return into a new wrapper object.

Map `LocalOCRError` to stable codes:

```text
file_not_found
file_not_readable
unsupported_format
invalid_pdf
invalid_page_range
invalid_output
output_exists
image_decode_failed
cancelled
processing_failed
```

Return tool failures with `isError=true`; do not throw service errors out of
the handler and do not terminate the server.

- [ ] **Step 7: Test every tool, default, partial result, and error**

Use a fake service to assert request mapping and exact result JSON. Include
unknown tool, unknown argument, relative path, partial PDF, partial batch,
and output-exists cases.

Run: `swift test --filter LocalOCRMCPTests`

Expected: All catalog, decoder, and dispatcher tests PASS.

- [ ] **Step 8: Commit the MCP contract layer**

```bash
git add Sources/LocalOCRMCP tests/LocalOCRMCPTests tests/contract/expected/mcp_tool_catalog.json
git commit -m "feat: define native MCP tool contracts"
```

---

### Task 5: Implement and Exercise the Stdio MCP Executable

**Files:**
- Create: `Sources/LocalOCRMCP/MCPServerRunner.swift`
- Create: `Sources/LocalOCRMCPExecutable/main.swift`
- Create: `tests/LocalOCRMCPTests/MCPServerRunnerTests.swift`
- Create: `tests/contract/test_native_mcp_server.py`

**Interfaces:**
- Uses the official MCP Swift SDK's `Server`, `StdioTransport`, `ListTools`,
  and `CallTool`.
- The process remains alive after recoverable tool errors.
- Standard output contains MCP frames only.

- [ ] **Step 1: Add a failing in-process registration test**

Inject a recording dispatcher and assert `ListTools` returns the catalog and
`CallTool` forwards the supplied name and arguments exactly once.

- [ ] **Step 2: Add a failing subprocess test**

Use the existing Python `mcp` client to spawn `.build/debug/localocr-mcp`.
Initialize the session, list tools, call `get_pdf_page_count`, send an invalid
`ocr_pdf` call, and then call `inspect_pdf` to prove the server survived:

```python
async with stdio_client(
    StdioServerParameters(command=str(binary), args=[])
) as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
        names = {tool.name for tool in (await session.list_tools()).tools}
        assert names == EXPECTED_TOOL_NAMES
        bad = await session.call_tool("ocr_pdf", {"file_path": missing})
        assert bad.isError is True
        good = await session.call_tool("inspect_pdf", {"file_path": fixture})
        assert good.isError is False
```

- [ ] **Step 3: Run both tests and verify failure**

Run:

```bash
swift test --filter MCPServerRunnerTests
.venv/bin/python -m pytest tests/contract/test_native_mcp_server.py -v
```

Expected: FAIL because the runner and executable do not exist.

- [ ] **Step 4: Register official SDK handlers**

Create a `Server` named `localocr` with version `0.2.0` and tool capability.
Register:

```swift
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: MCPToolCatalog.tools)
}

await server.withMethodHandler(CallTool.self) { parameters in
    await dispatcher.call(
        name: parameters.name,
        arguments: parameters.arguments ?? [:]
    )
}
```

Start `StdioTransport` with standard input and standard output. Let transport
EOF end the process cleanly. Propagate Swift task cancellation into service
calls and translate it to the `cancelled` tool error.

- [ ] **Step 5: Protect protocol stdout**

Do not use `print`, `dump`, `NSLog`, or `Logger` with stdout in either MCP
target. Add a subprocess assertion that captures stderr separately and proves
each stdout record is consumed by the MCP client. A startup failure writes one
concise message to stderr and exits nonzero.

- [ ] **Step 6: Build and run the executable-level tests**

Run:

```bash
swift build --product localocr-mcp
swift test --filter LocalOCRMCPTests
.venv/bin/python -m pytest tests/contract/test_native_mcp_server.py -v
```

Expected: All tests PASS; the server handles a failed call and a subsequent
successful call in the same session.

- [ ] **Step 7: Commit the stdio server**

```bash
git add Sources/LocalOCRMCP Sources/LocalOCRMCPExecutable tests/LocalOCRMCPTests tests/contract/test_native_mcp_server.py
git commit -m "feat: add native stdio MCP server"
```

---

### Task 6: Prove Python-to-Swift MCP Compatibility

**Files:**
- Create: `tests/contract/test_native_python_compatibility.py`
- Create: `tests/contract/expected/inspect_pdf.json`
- Create: `tests/contract/expected/ocr_pdf.json`
- Create: `tests/contract/expected/ocr_pdf_lines.json`
- Create: `tests/contract/expected/ocr_pdf_batch.json`
- Create: `tests/contract/expected/make_searchable_pdf.json`
- Modify: `tests/contract/test_native_mcp_server.py`

**Interfaces:**
- Launches the Python reference and native Swift server as separate MCP
  subprocesses.
- Normalizes only nondeterministic path, hash, and generated-output fields.
- Compares the six tool results and the tool schemas.

- [ ] **Step 1: Add a failing cross-server compatibility test**

For deterministic synthetic PDF and image fixtures, call the same tool with
the same arguments on both servers. Normalize:

- absolute fixture directory to `<fixture>`;
- valid SHA-256 strings to `<sha256>`;
- collision-generated output filenames to `<output>`;
- floating-point confidence and geometry to six decimal places.

Do not normalize page order, text, methods, failure arrays, orientation, or
the presence/absence of `lines`.

- [ ] **Step 2: Run the compatibility test and record real mismatches**

Run:

```bash
swift build --product localocr-mcp
.venv/bin/python -m pytest tests/contract/test_native_python_compatibility.py -v
```

Expected: FAIL with focused diffs for any remaining schema or semantic
differences.

- [ ] **Step 3: Align page-count and inspection contracts**

Preserve the legacy scalar integer for `get_pdf_page_count`. Match inspection
keys exactly: `source_path`, `source_sha256`, `pages`, `searchable_pages`,
`ocr_needed_pages`, `characters`, `fully_searchable`, and `page_details`.
`searchable_pages` and `ocr_needed_pages` remain integer counts in the MCP
wire result, even though `LocalOCRCore.PDFInspection` stores page-number
arrays internally.

- [ ] **Step 4: Align PDF OCR and optional line contracts**

Match `source_path`, `source_sha256`, `pages`, `failed_pages`,
`empty_ocr_pages`, and `rotated_ocr_pages`. Each page has `page`, `text`, and
`method`; add `lines` only when requested. Each line keeps the Python MCP
shape with flat `text`, `confidence`, `x`, `y`, `width`, and `height` fields.
Do not add the engine's per-page orientation or nested `bounding_box` fields
to the MCP result. Represent each rotated page as an object containing `page`
and the legacy string `orientation`.

- [ ] **Step 5: Align batch, image, and searchable contracts**

Batch output contains `processed`, `succeeded`, `failed`, and ordered
`results`. A successful item is the flat `ocr_pdf` result plus `status: "ok"`;
an error item has `source_path`, `status: "error"`, and string `error`. Keep
the legacy plain string result for `ocr_image`. Searchable PDF returns
`output_path` and `failed_pages`, and its output reopens successfully with
PDFKit.

- [ ] **Step 6: Write approved snapshots and rerun both implementations**

Generate expected JSON only after a human-readable diff shows intentional
compatibility. Commit normalized snapshots, not machine-specific paths.

Run:

```bash
.venv/bin/python -m pytest tests/contract -v
swift test
```

Expected: Native subprocess, cross-server compatibility, all Swift tests, and
all Python contract tests PASS.

- [ ] **Step 7: Commit compatibility fixtures**

```bash
git add tests/contract
git commit -m "test: verify native MCP compatibility"
```

---

### Task 7: Create Reproducible Native Tool Artifacts

**Files:**
- Create: `scripts/build-native-tools.sh`
- Create: `scripts/smoke-native-tools.sh`
- Modify: `.gitignore`
- Create: `tests/contract/test_release_artifacts.py`

**Interfaces:**
- Produces `dist/native-tools/localocr` and
  `dist/native-tools/localocr-mcp`.
- Artifacts are standalone arm64/x86_64-host Swift executables with only
  Apple system dynamic-library dependencies.
- Artifacts are unsigned here; the Mac app/release plan signs the final
  bundle with Developer ID.

- [ ] **Step 1: Add a failing artifact contract test**

Assert both files exist, are Mach-O executables, have no Python/Ruby/Homebrew
load paths, and print or negotiate version `0.2.0`.

- [ ] **Step 2: Run the artifact test and verify failure**

Run: `.venv/bin/python -m pytest tests/contract/test_release_artifacts.py -v`

Expected: FAIL because the artifacts and build script do not exist.

- [ ] **Step 3: Implement a clean release build script**

The script uses `set -euo pipefail`, determines the repository root from its
own location, runs:

```bash
swift package clean
swift build -c release --product localocr
swift build -c release --product localocr-mcp
```

It recreates only the repository-local `dist/native-tools` directory, copies
the two release executables, and does not codesign them. Add `dist/` to
`.gitignore`.

- [ ] **Step 4: Add binary dependency and privacy checks**

`smoke-native-tools.sh` runs `file` and `otool -L` on both outputs and fails
if output contains `.venv`, `python`, `/opt/homebrew`, `/usr/local`, or the
repository path. It runs a real CLI inspection and a real MCP initialization.
It also searches linked binary strings for `http://` and `https://`; any hit
must be traced to dependency metadata and removed or documented before
release.

- [ ] **Step 5: Build and verify artifacts**

Run:

```bash
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
.venv/bin/python -m pytest tests/contract/test_release_artifacts.py -v
```

Expected: Both Mach-O executables pass smoke tests and have only macOS system
framework/runtime dependencies.

- [ ] **Step 6: Commit artifact automation**

```bash
git add .gitignore scripts/build-native-tools.sh scripts/smoke-native-tools.sh tests/contract/test_release_artifacts.py
git commit -m "build: add reproducible native tool artifacts"
```

---

### Task 8: Document Installation, Manual MCP Setup, and Final Verification

**Files:**
- Modify: `README.md`
- Create: `docs/cli.md`
- Create: `docs/mcp.md`
- Modify: `pyproject.toml` only if a contract-test marker is required

**Interfaces:**
- Documents source builds and manual stdio client configuration.
- Does not install, edit client configuration, sign, notarize, or publish.

- [ ] **Step 1: Add documentation checks**

Add a contract test that verifies README commands reference the real product
names, all six MCP tools are documented, and example paths contain no
developer-machine-specific directory.

- [ ] **Step 2: Write CLI documentation**

Document every command and option from Task 3, exit codes, stdout/stderr
behavior, cache location and override, supported inputs, partial results, and
privacy guarantees. Include examples using `/path/to/document.pdf`, never a
personal path.

- [ ] **Step 3: Write manual MCP configuration**

Document the generic server command:

```json
{
  "command": "/absolute/path/to/localocr-mcp",
  "args": []
}
```

Explain that the server uses stdio, runs only while the client invokes it,
requires local filesystem access to supplied documents, and makes no network
requests. Link to current Codex and Claude client instructions rather than
hard-coding configuration locations that can change.

- [ ] **Step 4: Update the README**

Lead with the privacy promise, macOS 14 requirement, open-core scope, source
build commands, native CLI/MCP quick starts, six-tool table, testing, and the
fact that the Mac app and signed installer are the next milestone.

- [ ] **Step 5: Run the complete verification matrix**

Run:

```bash
swift package clean
swift build
swift test
.venv/bin/python -m pytest -v
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
git diff --check
git status --short
```

Expected:

- Swift debug and release builds succeed.
- All existing 75 core tests plus new service, CLI, and MCP tests pass.
- All existing 35 Python tests plus new contract tests pass.
- Both release executables pass the binary and privacy smoke checks.
- `git diff --check` emits no output.
- `git status --short` contains only intended documentation changes before
  the final commit.

- [ ] **Step 6: Commit the documentation**

```bash
git add README.md docs/cli.md docs/mcp.md pyproject.toml
git commit -m "docs: document native CLI and MCP server"
```

- [ ] **Step 7: Review the completed branch before merge**

Run:

```bash
git log --oneline --decorate main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
```

Review specifically for:

- exact six-tool compatibility;
- protocol stdout contamination;
- accidental network behavior;
- source-file overwrites;
- uncaught tool errors that terminate the server;
- Python or Homebrew runtime coupling;
- private fixture data or machine-specific paths;
- unpinned dependencies.

Expected: No unresolved findings. The branch is ready for review and merge.

---

## Completion Definition

This plan is complete only when:

- `localocr` and `localocr-mcp` build natively on macOS 14+;
- both executables share the same `LocalOCRService` and completed Swift engine;
- all six MCP tools match the Python server's established parameter and result
  semantics;
- the stdio server survives invalid and failed tool calls;
- image OCR works for ImageIO-decodable formats supported by Vision;
- release artifacts contain no Python, PyObjC, PyMuPDF, Homebrew, or network
  service dependency;
- all Swift, Python, subprocess, compatibility, and artifact tests pass;
- documentation explains manual use without editing client configuration;
- the release binaries are ready to embed and sign in the Mac app milestone.

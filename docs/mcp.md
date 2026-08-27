# LocalOCR MCP FAQ

Start with the LocalOCR Studio desktop app unless you specifically need an
agent to automate LocalOCR. The desktop app requires no MCP setup. This page is
the canonical advanced-use guide for connecting the `localocr-mcp` helper to an
MCP client.

The current published Beta 1 is the historical six-tool build. The source tree
described here contains a next-version candidate with nine tools and an
external-data acknowledgment. That candidate is not yet published; this page
does not claim a new version, signed package, notarization, installation, or
release acceptance.

## What does local stdio MCP mean?

The MCP client starts `localocr-mcp` as a local child process and exchanges
MCP messages over the helper's standard input and standard output. LocalOCR
does not open an HTTP port or expose a network MCP service. The helper exits
when the client closes that stdio connection.

LocalOCR itself uses Apple Vision, PDFKit, and optional Apple Foundation Models
on the Mac and makes no network request. Connecting an agent creates a separate
privacy boundary: the client decides which tool arguments and results enter its
conversation or provider. Local stdio describes the transport between the
client and helper; it is not a promise about the client's account, model, logs,
retention, or network behavior.

### Protocol compatibility and limits

`localocr-mcp` vendors an audited, stdio-only subset of the MCP protocol rather
than embedding HTTP, OAuth, EventSource, URLSession, or other network
transports. It supports normal generic, Codex, and Claude Code initialization
handshakes, then exposes the same nine LocalOCR tools over newline-delimited
JSON-RPC. The helper accepts at most 1 MiB of UTF-8 JSON per line (the newline
is excluded). Malformed or over-limit input receives a JSON-RPC parse error;
unknown methods receive method-not-found; notifications do not receive replies.
Protocol records are the helper's only stdout output. Closing stdin ends the
local session cleanly.

This transport boundary is not an external-provider boundary. A connected
client may still pass supplied paths, recognized text, tool arguments, or
results to its own service under that provider's privacy and retention terms.
LocalOCR does not change, audit, or inherit those terms.

## External-provider disclosure and consent

Every one of the nine document tools is blocked until the current LocalOCR MCP
acknowledgment has been accepted. Argument validation can occur first, but a
blocked tool does not open the requested document. This gate applies to the six
OCR/PDF tools as well as the three Local Intelligence tools because any tool
argument or result may be handled by the connected client.

LocalOCR and Apple Foundation Models process documents locally on this Mac,
and LocalOCR does not upload them. When you connect LocalOCR to an agent
through MCP, that MCP client or its AI provider may send filenames, paths,
document text, summaries, extracted fields, and tool results to an outside
service. Transmission, retention, model training, and other handling are
controlled by the agent and provider, not LocalOCR. Review their privacy and
data policies, and only continue if you are authorized to share the data.

Acceptance requires both statements:

- **I understand that my MCP client or agent may transmit LocalOCR inputs and results to an outside provider.**
- **I confirm that I am authorized to share this data and choose to enable LocalOCR MCP document tools.**

In LocalOCR Studio, open **Help > Connect to Your Agent**, check both statements
for that presentation, then choose **Accept & Enable MCP Tools**. The same
window shows receipt status and can revoke consent. An app installed in the
normal Applications folder includes a separate adjacent CLI helper at
`/Applications/LocalOCR Studio.app/Contents/Helpers/localocr`. Use that CLI
path—not the `localocr-mcp` server path—to manage consent:

```bash
"/Applications/LocalOCR Studio.app/Contents/Helpers/localocr" mcp-consent status
"/Applications/LocalOCR Studio.app/Contents/Helpers/localocr" mcp-consent accept
"/Applications/LocalOCR Studio.app/Contents/Helpers/localocr" mcp-consent revoke
```

Bare `localocr mcp-consent ...` is equivalent only when that CLI executable is
intentionally on the shell's `PATH`. Source-build commands use a different path
and are documented separately below.

`accept` requires an interactive terminal and two `y` or `yes` answers; there
is no noninteractive acceptance flag. `revoke` takes effect on the next tool
call, including in an already-running MCP session. The content-free local
receipt contains no document path, OCR text, or provider identity. A missing,
invalid, revoked, or outdated receipt fails closed.

## Advanced setup

LocalOCR only displays and copies setup instructions. It does not automatically
edit Codex, Claude Code, or another client's configuration, and it never runs
these commands for you.

### Installed LocalOCR Studio app

Use the actual absolute location of the app. For the normal Applications-folder
installation, the bundled helper path is:

```text
/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp
```

The same bundle contains two different executables:

- `Contents/Helpers/localocr-mcp` is the stdio MCP server configured in the client.
- `Contents/Helpers/localocr` is the CLI used for consent status, acceptance, and revocation.

### Codex

```bash
codex mcp add localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
codex mcp list
```

Use `/mcp` in Codex to inspect the connected server. The Codex CLI, IDE
extension, and desktop app share MCP configuration on the same Codex host. The
Codex has no project or user scope option for the installed `mcp add` or
`mcp remove` commands. Disconnect separately with
`codex mcp remove localocr`. See the
current [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp).

### Claude Code

```bash
claude mcp add --transport stdio --scope local localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

Use `/mcp` in Claude Code to inspect status. Claude Code defaults to
local scope for the current project; the command makes that scope explicit.
Add `--scope user` only when you intentionally want LocalOCR across projects.
Disconnect from the matching scope with
`claude mcp remove --scope local localocr`. See the current
[Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

### Other MCP clients

Use your client's current documentation to configure this generic stdio-server
entry; LocalOCR does not edit client configuration:

```json
{
  "command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp",
  "args": []
}
```

### Source builds for developers

Keep source-build paths separate from an installed app. From the repository
root, build a release executable and configure its absolute path:

```bash
swift build -c release --product localocr
swift build -c release --product localocr-mcp
codex mcp add localocr-source -- "/path/to/localocr/.build/release/localocr-mcp"
# Or, for Claude Code's current-project scope:
claude mcp add --transport stdio --scope local localocr-source -- \
  "/path/to/localocr/.build/release/localocr-mcp"
```

Manage consent with the CLI from that same source build:

```bash
"/path/to/localocr/.build/release/localocr" mcp-consent status
"/path/to/localocr/.build/release/localocr" mcp-consent accept
"/path/to/localocr/.build/release/localocr" mcp-consent revoke
```

The repository's `scripts/build-native-tools.sh` alternative writes
both `dist/native-tools/localocr` and `dist/native-tools/localocr-mcp`. Use the
first for consent commands and give the client an absolute path to the second.
The extension manifest invokes
`localocr-mcp` by name instead; put a built native executable on that client's
`PATH` before enabling the extension. The extension does not bundle an
executable or runtime.

The server starts when the client invokes it, communicates through standard
input/output for that session, and exits when the client closes the stdio
connection. The client process and helper need macOS filesystem permissions to
read the local document paths supplied to tools and to write a requested
searchable-PDF destination. Full Disk Access is not automatically required;
grant only the narrow access needed for the folders you choose. Relative paths are resolved from the server's
working directory; absolute paths avoid that ambiguity.

## Tools

All paths refer to local filesystem files. The server returns structured MCP
tool errors for bad arguments or processing failures and continues serving
later tool calls. It does not terminate merely because an individual tool call
fails.

### `get_pdf_page_count`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |

Returns the page count as text. Use it to plan a page range for large PDFs.

### `inspect_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |

Inspects the native text layer without running OCR. Its structured result has
`source_path`, `source_sha256`, `pages`, `searchable_pages`,
`ocr_needed_pages`, `characters`, `fully_searchable`, and per-page
`page_details`.

### `ocr_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |
| `page_range` (optional string) | 1-indexed selection such as `1-5` or `3,7,12`; omit for all pages. |
| `dpi` (optional integer) | PDF rasterization resolution from `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | OCR native-text pages too; default `false`. |
| `include_lines` (optional boolean) | Include per-line text, confidence, and normalized geometry; default `false`. |

Returns `source_path`, `source_sha256`, page records, `failed_pages`,
`empty_ocr_pages`, and `rotated_ocr_pages`. Pages with usable native text are
returned as `existing_text` unless forced; newly recognized pages are
`vision_ocr`. Page failures are reported without discarding successful pages.

### `ocr_pdf_batch`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_paths` (required array of strings) | One or more local PDF paths. |
| `page_range` (optional string) | Same 1-indexed selection as `ocr_pdf`. |
| `dpi` (optional integer) | `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | Same behavior as `ocr_pdf`; default `false`. |
| `include_lines` (optional boolean) | Same behavior as `ocr_pdf`; default `false`. |

Returns `processed`, `succeeded`, `failed`, and `results`. Each item is either
an OCR response with `status: "ok"` or a per-file `status: "error"` result.
One file's failure does not stop the rest of the batch.

### `ocr_image`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local ImageIO-decodable image path. |

Returns recognized text directly. ImageIO-decoded inputs include common PNG,
JPEG, TIFF, and HEIC/HEIF images, with the exact supported set determined by
the installed macOS ImageIO support. The MCP surface does not expose language
or cache options for image OCR.

### `make_searchable_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local source PDF path. |
| `output_path` (optional string) | New local PDF destination. If omitted, LocalOCR chooses a non-existing `<source-name>_searchable.pdf` variant. |
| `dpi` (optional integer) | PDF rasterization resolution from `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | OCR native-text pages too; default `false`. |

Returns `output_path` and `failed_pages`. The source is left untouched. The
output path must not already exist and must not resolve to the source file;
when `failed_pages` is non-empty, the new output is partial.

### `summarize_document`

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF or ImageIO-decodable image path. |

Recognizes the document locally, then returns a grounded `text` summary and
`citations`. Each citation identifies a one-based source `page` and an exact
`quote` from the recognized text.

### `organize_document`

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF or ImageIO-decodable image path. |

Returns a suggested `title`, `category`, up to five `tags`, and grounded page
`citations`. It suggests metadata; it does not rename, move, or alter the
source document.

### `extract_document_fields`

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF or ImageIO-decodable image path. |
| `fields` (required array of strings) | From 1 through 32 unique, non-empty requested names, each at most 128 characters after trimming. |

Returns only the requested names. Each field contains `name`, nullable
`value`, nullable one-based `source_page`, and nullable exact `evidence`.
Missing or unsupported values remain `null`; the model is not asked to fill in
facts without source support.

## Local Intelligence availability and privacy

The six OCR/PDF tools remain available on supported macOS 14-or-later Apple
silicon systems even when Local Intelligence is unavailable. The three tools
`summarize_document`, `organize_document`, and `extract_document_fields`
additionally require all of the following:

- macOS 26 or later;
- an eligible Mac for Apple Intelligence;
- Apple Intelligence enabled in System Settings;
- the on-device model ready after setup or download; and
- a currently supported Apple Intelligence language.

The helper reports distinct unavailable states when the OS is too old, the Mac
is not eligible, Apple Intelligence is not enabled, the model is not ready, or
the current language is not supported. These states do not disable ordinary
OCR and PDF tools.

Local Intelligence sends only required recognized text and page markers to
Apple's on-device Foundation Models framework. It does not pass the source PDF
or image bytes to the model. LocalOCR does not use Private Cloud Compute, a
third-party model, an API key, or any network model, and there is no cloud
fallback. The outputs are constrained to the requested summary, organization,
or named-field task and checked against source text before being returned.

That local LocalOCR boundary ends at the MCP client. The client may send paths,
arguments, recognized text, and results to its configured service, so do not
assume that data remains on your Mac. Codex, Claude Code, and other clients own
their configuration and account terms; their privacy, retention, training, and
provider behavior may change. Check the current authoritative client
documentation and your account settings before using sensitive material.

## Safe first connection

Use a fictional, non-sensitive fixture in a folder the client can read, and
request a narrow result. For example:

- “Inspect `/Users/Shared/LocalOCR Test Files/test-invoice.pdf` and report only its page count and whether it already has searchable text.”
- “OCR `/Users/Shared/LocalOCR Test Files/test-scan.png` and return only the recognized text.”
- “Summarize `/Users/Shared/LocalOCR Test Files/test-letter.pdf` in three factual bullets using Local Intelligence.”

Keep the original document. OCR and model outputs can contain recognition or
interpretation errors, and beta output contracts may change. The read-only
tools do not modify the source. `make_searchable_pdf` writes a separate new
file and refuses to overwrite an existing destination or the source.

## Local behavior and privacy

The server exists only for the client-managed stdio session and accesses local
files only when a tool call supplies their paths. PDF OCR may write local cache
entries at the same default cache location as the CLI,
`~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; set
`LOCALOCR_CACHE_DIR` in the server's environment to use a different local
cache directory. Apart from those local cache writes, its only output write is
a new searchable PDF at a local destination requested by `make_searchable_pdf`.
That destination must not already exist and must not resolve to the source
file. The server itself makes no network requests.

## Troubleshooting

### Helper path

If the client reports that the command does not exist, confirm the app's real
location and use its absolute
`<installed-app-path>/Contents/Helpers/localocr-mcp` path. Do not use the
installed-app pattern for a source build; point to that checkout's absolute
`.build/release/localocr-mcp` or `dist/native-tools/localocr-mcp` instead.

### Client connection

Run `codex mcp list` or `claude mcp list`, then use the client's `/mcp` view if
available. Confirm that the entry uses stdio and has no HTTP URL. Restart the
client after a manual configuration change if its current documentation says
that is required.

### Filesystem permissions

If a tool cannot read a path or write a destination, verify the path and the
permissions granted to the MCP client that launches the helper. Prefer a small
test folder such as `/Users/Shared/LocalOCR Test Files` over broad permissions.
The helper cannot bypass macOS privacy controls or sandbox restrictions.

### Consent required

If a tool returns `external_data_acknowledgment_required`, inspect with
`localocr mcp-consent status`, then accept interactively in the CLI or use
**Help > Connect to Your Agent** in Studio. If policy text changes later, the
old receipt becomes outdated and fresh acceptance is required. To disable all
document-tool access, run `localocr mcp-consent revoke` or revoke it in Help.

### Local Intelligence unavailable

First confirm macOS 26 or later and an eligible Mac. Then confirm Apple
Intelligence is enabled, its model download/setup is complete, and the current
Apple Intelligence language is supported. When those conditions are not met,
use the six OCR/PDF tools; LocalOCR has no cloud fallback.

## Compatibility and release boundary

The package and app keep a macOS 14 deployment target; Foundation Models code
is availability-guarded for macOS 26 or later. Development compilation and
automated verification for this candidate use stable Xcode 26.6 (`17F113`),
Swift 6.3.3, and the macOS 26.5 SDK. That is development evidence, not a live
Foundation Models run or release acceptance. Published Beta 1 provenance and
its separate macOS 27 beta acceptance evidence remain documented in the
[Beta Tester Guide](../BETA_TESTING.md). None of that historical evidence is a
signature, notarization, download, or target-Mac acceptance claim for this
next-version candidate. Those remain separate release gates.

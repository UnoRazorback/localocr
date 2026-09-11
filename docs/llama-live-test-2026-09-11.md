# Live llama.cpp test — 2026-09-11

Status: NOT READY for grounded LocalOCR intelligence. No signed-app acceptance or release is claimed.

## Host and runtime

MacBook Air, 24 GiB RAM. Copied the existing arm64 runtime from the MacBook Pro into a separate Air test directory. Runtime reports `version: 0.4.0-dev (build 10909, commit a2878d30d)`. Temporary servers bound only to 127.0.0.1:8080, one slot, 4096-token context, reasoning off, no web UI. Only the test servers created here were stopped; existing other model services and user selection were preserved. No model server was started on the Pro.

## Findings and changes

1. Real version output differs from the original fixture. Added a failing regression and accepted the bounded semantic-version/build/commit format alongside the older build/hash format. Invalid commits remain rejected.
2. macOS lsof emits numeric f-descriptor records even with -Fpn. Added a failing real-output fixture and accepted numeric descriptor records only after a process record. Unique PID and exact loopback listener requirements remain.
3. Version subprocess exceeded the original five-second bound. Initial GPT test coincided with 5% free memory and 13 GB swap; smaller-model testing also saw delays, so memory is not a complete causal explanation. A direct probe returned valid output after 13.14 seconds. Increased only version command timeout to 30 seconds, retaining outer request deadlines, bounded streams, cancellation and identity checks.
4. Live process attestation passed after these changes. Added an opt-in live attestation test; default runs do not require a server.

## Actual operations

- GPT-oss-20b-MXFP4 loaded and served health metadata. SHA-256: 27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901.
- Existing smaller Gemma E4B Q4_K_M loaded for a lower-memory diagnostic. This is NOT the transferred Gemma 26B model.
- `localocr intelligence test llama_cpp gemma-4-E4B-fixture --json`: exit 2, failed summary/organization/extraction, zero passed actions.
- `localocr intelligence test llama_cpp gpt-oss-20b-MXFP4 --json`: exit 2, failed summary/organization/extraction, zero passed actions.
- Separate synthetic GPT probe returned inline analysis markers despite reasoning-off settings. This demonstrates a response-mode concern, but does not by itself establish the cause of every qualification failure. Do not relax validation or strip reasoning to force qualification.
- `inspect mixed.pdf --json`: exit 0, two pages, one searchable and one requiring OCR.
- `ocr image-only.pdf --json`: exit 0, two recognized pages, no failed or empty OCR pages.
- `image upright-text.png --json`: exit 0, recognized LOCAL OCR TEST 123.
- No document intelligence CLI results were approved: qualification failed before selection. Existing Apple selection was not changed. Never present OCR success as model-intelligence success.

Final default Swift run: 795 tests / 61 suites passed, with the opt-in live test disabled. An earlier run while the model was resident had one LM Studio fixture command failure; it is retained in the workspace log. This follow-up has not rerun the full Python release suite or rebuilt signed binaries.

## Next diagnostic gate

Capture each synthetic qualification operation's adapter error and validation outcome in an opt-in test harness; separate envelope/schema rejection, grounding rejection and semantic fixture rejection. Test reasoning/JSON behavior against pinned runtime documentation before changing requests. Repeat with the transferred Gemma 26B on the Pro under its owner's controlled launch. The main qualification policy must remain unchanged unless a separately reviewed defect is reproduced.

## Transfer

Destination `/Users/scottray/Library/Application Support/BuceesDev/models/`. Gemma main and mmproj copied and both destination checksums passed. GPT transfer continues separately. Each model directory has commented repository URL, revision, source URL, byte size and standard SHA-256 lines. No models are inside a Git repository.

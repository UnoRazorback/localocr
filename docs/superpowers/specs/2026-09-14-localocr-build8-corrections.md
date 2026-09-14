# LocalOCR 0.3.1 Build 8 Corrections

## Goal

Produce a private LocalOCR 0.3.1 build 8 candidate that preserves document layout for grounded intelligence, accepts one narrowly attested GPT-OSS 120B response shape, and does not falsely invalidate an unchanged verified llama.cpp process during sustained use.

## Source evidence

- Build 7 source base: `0a62c1a64aad490fb467ac745a79d877c74f7ee6`.
- Pro request: `work/localocr-build8-handoff-20260914/request.json`.
- Synthetic fixture SHA-256: `0b3da28392e67b6f55a111561305ad0faad90335dcfb18390e48c28dc51b2d74`.
- Current failed extraction SHA-256: `ff96cd75bcef036e0c50948292a87ddd9fa8dcbe7e481e401ecc6b96cd41205b`.
- Approved GPT-OSS 120B identity: runtime alias `gpt-oss-120b-mxfp4` plus GGUF SHA-256 `582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`, from the immutable `ggml-org/gpt-oss-120b-GGUF` revision `238abdd290bb874b90a5da1b4549881b7d05c091` delivery manifest. The machine-specific GGUF path remains private runtime configuration and is not embedded in source or release records.
- Pro real-data evidence supplied by Scott on 2026-09-14: Apple Vision OCR completed a 22-page readiness PDF in 0.532 seconds; a schema-valid grounded Gemma Q8 summary completed in 32.25 seconds; the immediately following organize operation failed and discovery reported the unchanged selected process unavailable while `llama-server` remained on port 8080. Only a content-free SHA and timing manifest was retained.

## Requirements

### Layout-aware intelligence input

1. Preserve ordinary OCR output and native-PDF text behavior.
2. Request line geometry when loading PDF text for intelligence.
3. For Vision OCR pages with valid line geometry, deterministically cluster vertically overlapping lines into rows, sort cells left-to-right, and serialize cells with ` | ` so row and column associations survive.
4. Do not merge materially misaligned lines. Invalid/non-finite/out-of-bounds geometry must fall back to the existing page text, not become trusted structure.
5. The synthetic page must expose `Equipment | Lift and delivery | $2,000.00` as one grounded row, allowing extraction of equipment value `$2,000.00` from page 1.

### GPT-OSS-only response adapter

1. The exception is enabled only when the provider is `llama_cpp`, the attested runtime alias is exactly `gpt-oss-120b-mxfp4`, and the attested model fingerprint is exactly `582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`.
2. For that identity only, permit exactly one additional assistant-message member named `reasoning_content` whose value is a string no larger than 65,536 UTF-8 bytes. Discard it before final validation.
3. Continue to require exactly one choice, index 0, assistant role, string `content`, `finish_reason == "stop"`, no tools, no extra keys, no inline `<think>` markers, a matching response model, the existing strict final JSON schema, unchanged pre/post identity, unchanged metadata, and grounded final content.
4. Gemma and every other identity must continue to reject `reasoning_content`.

### Sustained-use locality

1. Preserve listener, PID, argv/environment, file identity, hashes, loopback endpoint, model metadata, and pre/post generation checks.
2. Cache only a successfully parsed `llama-server --version` result, keyed by the immutable pinned executable identity already used for digest caching. The cache must be private, regular, owner-only, non-symlinked, bounded, atomically published, and revalidated against the pinned executable before use.
3. Cache miss or executable identity change must run the bounded version command again. Invalid or unsafe cache state must fail closed.
4. A version-command timeout is an operational timeout, not evidence that locality changed. It must not be mapped to `locality_unverified`.
5. Twenty sequential operations against an unchanged verified process followed by a ten-minute idle must not mark it unavailable or invalidate qualification.

### Acceptance and release

1. Two consecutive six-operation synthetic harness passes.
2. Synthetic change-order extraction returns equipment `$2,000.00` on page 1.
3. Two consecutive full qualifications for Gemma Q8 and two consecutive full qualifications for GPT-OSS 120B.
4. Twenty sequential synthetic operations plus a ten-minute idle with unchanged PID, alias, fingerprint, and listener and no false locality loss.
5. Exactly one content-free 17-key Local AI Activity record per generation, readable by AI Neural Gauge.
6. Repeat Swift, Python, native build, smoke, style/policy, packaging, signature, dependency, notarization, stapling, and Gatekeeper checks. Build success alone is not model acceptance.
7. Deliver the signed/notarized private candidate and exact acceptance instructions directly to the Pro. Do not publish publicly, merge to a shared branch, start a Pro model server, use company documents, or weaken any other provider boundary.

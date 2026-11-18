# LocalOCR 0.3.2 build 11 — local-model provider and Gauge acceptance

Date: 2026-11-17 (US Central; 2026-11-18 UTC). Target: the signed, notarized
build 11 installed at `~/Applications/LocalOCR Studio.app` on the MacBook Pro
(macOS 27.2.1, 128 GB), published as `v0.3.2-beta.2`. Requested by the owner
after publication. Logs: the project's `releases/0.3.2-11/provider-acceptance/`.

Only the repository's synthetic fixtures (`mixed.pdf`, `image-only.pdf`) and a
generated 24-page synthetic document were sent to a model. The selection was
Apple Foundation Models before the run and was restored to it afterwards; no
server was left running.

## Result

| Provider | Result |
| --- | --- |
| Apple Foundation Models (`SystemLanguageModel.default`) | PASS, with one output-quality finding (below) |
| llama.cpp `b10909`, Gemma 4 26B A4B Q4_0 | PASS, with one output-quality finding (below) |
| LM Studio | NOT RUN: installed, not running, and its local server is started from its own app |
| Ollama | NOT RUN: not installed on this Mac |
| AI Neural Gauge 0.3.1 (5) | PASS for completed jobs; a running job was confirmed in the shared ledger but not read from the Gauge window |

Not run: Gemma Q8 and gpt-oss models, endurance, real idle, the controlled
macOS 27 GR target run, and any real document.

## Apple Foundation Models

- `summarize`, `organize`, `extract-fields` on both fixtures through the signed
  CLI: six of six exit 0 with one JSON object, seven-key `local_model`, and every
  citation and evidence quote found on its cited page.
- The same three operations through the signed `localocr-mcp` helper
  (`summarize_document`, `organize_document`, `extract_document_fields`): three
  of three returned without error, provider `apple_foundation_models`.
- Each CLI operation added exactly one ended Local AI Activity record with the
  17 approved keys, `runtime_family` `foundation_models`, and no document
  text, file name, path or model path.

**Finding.** Asked for `Original Contract Sum` on `image-only.pdf`, whose only
amount is "Retainage withheld this period totals $144,904.17", the Apple model
returned `$144,904.17` with that sentence as evidence. The quote is on the
page, so grounding passed, but the amount is not the requested field. Gemma
returned null for the same request. Grounding proves the text exists on the
page; it does not prove the value answers the question.

## llama.cpp

Started with the owner's operator script (`LocalOCRModelRuntime/start-model.sh
gemma`), which uses the attested argument set. A first attempt with extra
flags (`--ctx-size`, `--parallel`, `--no-mmproj`) was correctly refused by the
signed helper as locality unverified.

- Discovery: one `llama_cpp` model, `verified_local`.
- Qualification: all three actions passed (13 s), fingerprint
  `3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d`; passed
  again after each server restart, as the design requires.
- Selection through the typed acknowledgment (answered by the acceptance
  script on the owner's instruction, for synthetic input only).
- Six of six CLI operations and three of three MCP tool calls passed, provider
  `llama_cpp`, about 3 s each; a 24-page synthetic document summarized in 13 s
  with 12 citations.
- Each CLI operation added exactly one ended, content-free activity record,
  `runtime_family` `local_runtime`, `runtime_identifier` null.
- With the server stopped: status `invalid` / `locality_unverified`,
  `summarize` exits 2 and writes nothing to standard output, ordinary OCR still
  works.

**Finding.** `organize` returned an empty `title` for both fixtures.

## AI Neural Gauge

- The Gauge holds the shared group entitlement and was running.
- Read from its window after the llama.cpp run: "Last completed workload, Local
  runtime · LocalOCR CLI, Completed successfully … Extracting, On-device
  loopback … Model identity not reported, Reported by a participating app",
  and the recent-activity list showed the Summarizing, Organizing and
  Extracting jobs in order. No document or model detail was shown.
- During a running job the shared ledger held one `active` record with a
  45-second lease and heartbeat, which moved to `recent` when the job ended.
  The Gauge window could not be read at that moment (it exposed no elements
  to accessibility), so the "running" state was not confirmed on screen.

## Automations

A search of the Codex skills and automations, the Claude Code workspace,
automation contexts and launch agents found no workflow that calls
`summarize_document`, `organize_document`, `extract_document_fields` or the
matching CLI commands. Two context documents mention that the tools exist.
Skills stored only in the Claude account were not searchable from the Mac.

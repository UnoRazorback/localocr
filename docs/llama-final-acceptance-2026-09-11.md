# Completed local llama.cpp test pass — 2026-09-11

**Readiness: NOT READY. Testing is complete for this pass; the qualification gate remains closed.**

## Model matrix

| Model | Load/health | Real attestation | Qualification | Limitation |
|---|---|---|---|---|
| GPT-oss-20b MXFP4 | Pass | Pass after parser fixes | Summary, organization, extraction failed | Separate synthetic response included inline reasoning markers despite reasoning-off settings; do not assume this alone explains every failed action. |
| Gemma 26B A4B Q4_0 | Pass | Pass | All three actions failed | Initial default batches caused Metal out-of-memory. Retry with batch-size 128 / ubatch-size 64 generated without that error, but still failed qualification. |
| Existing Gemma E4B Q4_K_M diagnostic model | Pass | Pass | Failed | Direct grounded summary and extraction succeeded; organization invented annotations in evidence and was rejected. This smaller model is not the transferred Gemma 26B. |

All servers used only 127.0.0.1:8080, one slot, 4096-token context, no web UI, and reasoning off. Gemma used no-mmproj for text-only tests. All temporary Air servers were stopped. No server was started on the MacBook Pro. Existing other services and the user's Apple model selection were preserved.

## Why partial success is not qualification

The real fixture responses exposed a distinction in existing policy: `LocalModelQualificationService.canonicalSummaryDomain` requires the citation quote to equal the complete fixture page, while ordinary grounding accepts exact source substrings. The smaller model returned exact but shorter quotes and fragmentary fact labels. Organization also returned invented `(page 2)` suffixes inside purported exact quotes. Extraction's absent values sometimes used the string `nil`; the existing grounded engine discarded unsupported fields rather than accepting them.

The follow-up direct adapter/provider test established grounded summary and extraction success on synthetic input, not a qualified model or an end-to-end approved CLI result. A helper-process diagnostic likewise returned valid summary payloads. Its extraction attempt was interrupted by the diagnostic model switch and timed out, so that attempt is not used as success evidence or evidence of a transport defect.

No qualification rule was weakened, no reasoning stripped, and no receipt manufactured. Native/scanned document intelligence commands remain gated because no tested llama.cpp model qualified. Ordinary OCR success does not clear that gate.

## Remaining work

1. Review the qualification fixture's complete-page citation requirement against the intended provider contract. If it is intended, communicate the requirement consistently through general grounded prompting; if it is a validator defect, add adversarial and legitimate-substring regression cases before a reviewed change. Do not optimize prompts to memorize fixture answers.
2. Establish a supported strict-JSON/no-reasoning request configuration for the pinned runtime/model pair; never sanitize a disallowed answer into a pass.
3. Repeat qualification, then interactive selection and all six native/scanned CLI operations only after passing. Continue with signed-app/Gauge integration afterward.
4. The Pro should use its owner's controlled runtime launch and suitable memory settings. Air OOM is host/configuration evidence, not proof that Gemma cannot work on the Pro.

## File transfer completed

Both Gemma files and GPT-oss are in `/Users/scottray/Library/Application Support/BuceesDev/models/`, in the exact requested subdirectories. All three destination SHA-256 checks returned OK. Per-model SHA256SUMS.txt files include repository URLs, immutable revisions, source URLs, sizes and hashes. The destination is outside Git. No model server was started on the Pro.

Full diagnostic logs and structured outcomes are retained in the Air workspace `work/llama-*` and `work/mbp-model-transfer-status.json`. The report records failed acceptance explicitly; source commit 06c8d05 contains the earlier version/lsof fixes and bounded version-probe adjustment.

## Final stopped-server checks

After stopping the last test server: inspect mixed.pdf exit 0; OCR image-only.pdf exit 0; image upright-text.png exit 0; qualification of the unavailable llama.cpp model exit 2. JSON outputs and stderr are saved separately in `work/*-final.stdout` and `work/*-final.stderr`. No fallback model was selected.

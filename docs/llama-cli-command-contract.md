# One-shot Local Intelligence CLI and MCP contract

The CLI exposes the same document intelligence operations as MCP through the selected local provider:

```sh
localocr summarize invoice.pdf --json
localocr organize scan.png --json
localocr extract-fields invoice.pdf --field date --field total --json
```

`--field` repeats once per requested field. Names are trimmed, nonempty, unique after trimming, and at most 128 characters each. Extraction requires 1–32 names. Invalid arguments fail before reading the document. These commands also emit JSON when `--json` is omitted.

The shared document loader uses existing PDF text where available and OCR where needed; supported images use OCR. The selected provider router, chunking and grounding validation remain in the execution path. Commands do not select a model, qualify a model, accept an acknowledgment, download a model, or fall back to another provider. Use the existing `localocr intelligence` management commands to inspect and explicitly select a qualified model first.

## Success output

A successful command writes exactly one JSON object and newline to stdout, with exit status 0. Diagnostics belong on stderr. The operation payload matches its MCP equivalent:

| CLI | MCP | Payload keys |
| --- | --- | --- |
| `summarize` | `summarize_document` | `text`, `citations`, `local_model` |
| `organize` | `organize_document` | `title`, `category`, `tags`, `citations`, `local_model` |
| `extract-fields` | `extract_document_fields` | `fields`, `local_model` |

CLI results additionally include `source_path` (standardized absolute path) and `source_sha256` (lowercase SHA-256). The source is hashed before loading and again before emitting the result. If its bytes changed, the command fails without emitting a result. This check does not lock the source against concurrent writers.

Citations contain `page` and `quote`. Extracted fields contain `name`, nullable `value`, nullable `source_page`, and nullable `evidence`. Missing values remain JSON null; they are not synthesized.

## Provider-agnostic model metadata

Every operation encodes the provenance returned by the provider router. The `local_model` object has exactly these seven required keys, with no additional properties:

| Key | JSON type | Meaning |
| --- | --- | --- |
| `provider_id` | string | Stable provider identifier, e.g. `apple_foundation_models`, `ollama`, `lm_studio`, `llama_cpp` |
| `provider_display_name` | string | Human-readable provider name |
| `model` | string | Actual model identifier |
| `processing` | string enum | `on_device` or `on_device_loopback` |
| `fingerprint` | string or null | Model fingerprint when available |
| `harness_version` | string or null | Harness version when available |
| `qualified_at` | string or null | ISO-8601 qualification timestamp when applicable |

Apple's system model emits null for fingerprint, harness version, and qualification timestamp. Loopback providers emit their actual model provenance. Nullable fields are present even when null.

### Migration from the previous MCP schema

The previous schema hard-coded Apple provider/model constants and a `provider` display-name field. Consumers must replace `local_model.provider` with `provider_display_name` for presentation, use `provider_id` for branching, accept the provider's actual `model`, and handle both processing values. Strict decoders must add all three nullable attestation fields. The shared CLI/MCP encoder and MCP catalog use the same seven keys; MCP's top-level operation payload keys remain unchanged. MCP's existing external-data acknowledgment gate remains required.

## Failures

Failure emits no operation JSON. Existing process exit categories remain: 1 for processing failures, 2 for argument/selection failures, and 4 for cancellation. Selection and intelligence diagnostics contain machine-readable codes after `error:`; examples include `selection_corrupt` (including no selection), `qualification_required`, `model_unavailable`, `provider_unavailable`, `acknowledgment_required`, `identity_changed`, `generation_timed_out`, `malformed_output`, and `ungrounded_output`. Missing/unreadable source preflight errors use `file_not_found` and `file_not_readable`; a changed source uses `source_changed`. Invalid options or field requests include an explanatory argument diagnostic. MCP retains its existing stable error codes, including the `local_intelligence_` prefixes where applicable.

## Verification

`DocumentIntelligenceCommandTests` exercises all three commands, compares decoded CLI and MCP results after removing CLI source metadata, checks source hashing and native-first PDF defaults, accepts the maximum field count/length, rejects invalid bounds and duplicates, and verifies missing/stale/unavailable selections fail with no bridge or Apple fallback calls. MCP dispatcher and catalog tests check actual provenance, nullable fields, strict keys, and the checked-in catalog snapshot.

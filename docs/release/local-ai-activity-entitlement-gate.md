# Local AI Activity production entitlement gate

Configuration authorized in Scott's 2026-09-12 suite-completion task; signed runtime and distribution acceptance remain pending. This records configuration and required evidence, not a completed installation or publication.

The explicit macOS App Group is `DZ8B5454ZN.com.rayconsulting.local-ai-activity`, owned by team `DZ8B5454ZN`. The payload-free wake name is `com.rayconsulting.local-ai-activity.changed`. The team-prefixed macOS group uses macOS team authorization; do not substitute the iOS `group.*` registration convention or claim a mobile provisioning profile has been configured.

Production scope is LocalOCR Studio, `Contents/Helpers/localocr-mcp`, and `Contents/Helpers/localocr`. Each code object must carry `com.apple.security.application-groups` with this exact group. Sign nested helpers first and the containing app last. `localocr-model-bridge` is not a direct producer and remains outside the group.

The common `LocalAIActivityProduction` factory validates the running code signature, approved team and group entitlement before asking FileManager for the container. It verifies the secure ledger directory before enabling reporting. Missing authorization, unavailable container, or insecure storage disables reporting; inference continues. No environment, parent bundle, home-directory, or arbitrary path fallback exists. This explicit configuration works when a signed helper's Bundle.main has no application Info.plist. Tests inject authorization and temporary container resolvers; unsigned builds do not automatically join official reporting.

The 17-key schema is unchanged. All external runtimes, including llama.cpp, emit `runtime_family=local_runtime` and `runtime_identifier=null`; model names, paths, endpoints, text and arguments are never copied into activity records. Vision OCR alone emits no inference record. The optional distributed notification contains no payload and only requests a rescan.

Pending evidence before claiming production sharing:

1. Inspect exact signature, team and group entitlement for each helper and containing app; ensure the bridge remains outside the group.
2. Verify container authorization and content-free producer-to-reader active and ended lifecycle using synthetic input on the signed installation. Verify disabled reporting cannot break inference.
3. Complete Developer ID signing, Hardened Runtime, notarization, stapling, Gatekeeper, archive extraction and second-Mac verification under the parent suite's authorization. Record commands, code-object hashes and results separately from unit tests.

Future iOS and iPadOS configuration needs its own registered identifier, provisioning profiles and device acceptance; this macOS configuration is not mobile authorization. Merge and public publication remain separate from implementation and testing.

# LocalOCR llama.cpp and one-shot CLI handoff

Source branch: `feature/llama-cpp-intelligence-cli`, based on `a01fa1e`.

This change implements the named same-Mac `llama_cpp` provider, process/file attestation and cached hashes, one-shot grounded CLI operations, and the shared strict seven-key CLI/MCP model-provenance contract. See `llama-cpp-locality.md` and `llama-cli-command-contract.md` for behavior and consumer migration.

## Validation environment

The MacBook Air has mismatched default SDK resolution between Xcode and Command Line Tools. Final verification uses these per-process settings, without changing global toolchain configuration:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

Build native helpers before the Python contract suite, which requires them. Run build/test commands sequentially because release fixtures clean Swift build output. Initial failures from stale policy inventories, SDK mismatch, and concurrent build cleanup are retained in the workspace logs; they are not acceptance results.

Final results are recorded in the transfer package's `validation-results.json` with full logs. Source tests and unsigned native builds do not establish signed-app or target-machine acceptance.

The SDK-pinned full Python run produced 463 passed, 1 skipped, and 3 failed in 820.11 seconds. One fixture missed its 30-second FIFO rendezvous and passed alone on rerun (28.67 seconds). Two checks rejected an unexpected `LocalOCR Studio 2` executable in the generated unsigned app before reaching their intended assertions. That extra file had the same SHA-256 as the legitimate executable (`5376532b74e8473bca0b8af3458b1a158d8577441c485c7119a2fa4ccdb31cd3`) and was moved to a workspace quarantine. Both affected checks then passed on a fresh fixture rebuild (138.42 seconds). The exact narrow rerun results are included separately; do not describe the original full run as green.

## MacBook Pro acceptance still required

1. Import the source branch into an isolated checkout and review the changes against the target checkout; preserve any existing MBP work.
2. Repeat the Swift/Python/build/smoke checks with a coherent installed Xcode SDK.
3. Use the project's release process to sign, notarize, staple, and install the app. Verify signature and ticket plus all three executable helpers.
4. Verify transferred model SHA-256 hashes. Launch a single local `llama-server` explicitly bound to literal loopback port 8080, with exactly one local GGUF, explicit alias, no web UI, and reasoning disabled. The separately downloaded Gemma projector is not accepted by this text-only provider.
5. Discover, qualify against the synthetic fixture, select interactively with acknowledgment, and inspect persisted provenance. Model/executable changes or server restart require requalification.
6. Run summarize, organize, and extract-fields on a fictional native-text PDF and scanned PDF. Check quotes and page references against recognized text.
7. Stop the server: intelligence must fail without fallback while inspect, OCR, and image commands continue working.
8. Observe actual network behavior on the target Mac; confirm document processing uses only the approved loopback route and no document contents or identifiers leave the Mac.

No public release, installed-app replacement, real-model inference, or MBP transfer is established by this source handoff. Download staging is separate from application model lifecycle controls.

# llama.cpp acceptance progress

## Verified behavior

- Gemma 4 26B A4B Q4_0 passed actual LocalOCR CLI qualification for summary, organization and extraction. Qualification/grounding rules were not changed.
- Fixed request reasoning_format from none (raw thought markers remain in content) to auto, with enable_thinking=false. Responses still reject reasoning fields, tool calls, malformed JSON and identity changes. The nine adapter tests passed after a failing regression demonstrated the old request setting.
- General grounded prompts now preserve complete source relationships, require verbatim evidence, distinguish JSON null from literal nil strings, and interpret requested field names semantically without inventing values. No fixture-specific answers appear in prompts.
- Six one-shot CLI commands passed: summarize, organize and extract-fields on existing mixed.pdf and image-only.pdf. Independent checks verified every returned quote against its one-based recognized page and every source SHA-256 against the input file. The contract sum was correctly extracted as $57,508,601.00 from native page 1.
- Selected the qualified model through the interactive acknowledgment for synthetic tests, stopped the owned server, verified intelligence exit 2 (locality_unverified), verified ordinary OCR still worked, and restored Apple selection. No Pro server was started.

## Xcode 27 RC

All new build work uses Xcode 27.0 build 27A266a at /Applications/Xcode-27-RC.app. Native helper build and native smoke scripts passed. The reviewed source inventory now includes the previously committed opt-in LlamaCppLiveDiagnosticTests.swift; removal of exactly that file reproduces the prior inventory hash.

Swift test with a private scratch path found one test executable lookup failure under the new Swift Build layout. Lookup now also checks the actual test bundle directory. Its 15-test suite passed afterward. The final full repeat completed with 795 tests, zero reported issues, and two opt-in live tests skipped. A separate pre-existing UI test used two scheduler yields to assume an asynchronous failure completed; it now waits up to two seconds for the transition and preserves its exact error assertion. The full Python run recorded 465 passed, one skipped and one candidate-cleanup failure. That cleanup test subsequently passed with the corrected Xcode 27 environment. The four toolchain guard tests and all 32 Studio project/packaging tests passed after the final build metadata update. This is not a claim that the original full Python run passed.

Native release packaging explicitly uses SwiftPM native backend (deprecated but supported by Xcode 27) to preserve the existing guarded artifact layout. Future removal of that backend requires an explicit packaging migration, not an older compiler fallback.

## Evidence

Air workspace work/llama-semantic-gemma26-qualification.json; work/llama-document-acceptance/results.json and evidence-validation.json; work/llama-native-27rc-build-reviewed.log; work/llama-native-27rc-smoke.log. Failed diagnostic runs remain preserved alongside successful results.

Not yet notarized or installed on the Pro. Signed candidate verification is recorded below.

## Final prompt and build 5

Independent review identified excessive evidence repetition for long passages and missing physical xcodebuild validation. Both were corrected and re-reviewed. Short passages up to 250 characters remain cited in full; longer passages request the smallest complete supporting passage, with related facts grouped. Qualification rules remain unchanged.

Fresh final-prompt qualification passed all three actions (2026-09-12T04:47:24Z). All six PDF commands passed again with independently checked source hashes and exact page evidence. With the owned Air server stopped, summarize exited 2 with locality_unverified, ordinary OCR exited 0, and intelligence reset restored Apple selection. No Pro server was started.

Final evidence: work/llama-final-swift-repeat.log; work/llama-cleanup-rc-retest.log; work/llama-build5-project-rc-tests.log; work/llama-final-prompt-qualification.json; work/llama-final-document-acceptance/results.json, evidence-validation.json, stopped-results.json. Earlier unsuccessful runs remain retained.

Release metadata is 0.3.1 build 5, distinct from the Pro's installed build 4. Packaging/signing/notarization remain separate from the passing development-helper acceptance. The Air has a Developer ID signing identity but no saved LocalOCR notarization profile; the checked Mini and Pro keychains were locked. Awaiting Scott's identification of an unlocked signing machine. Do not install an unnotarized candidate as the completed release.

## Signed candidate

The unsigned Studio build, release staging (including rebuilt native helpers and MCP/loopback policy checks), and Developer ID signing all exited 0. Independent codesign --verify --deep --strict passed for the app; each of localocr, localocr-mcp and localocr-model-bridge passed individual strict verification. The candidate is 0.3.1 build 5 at dist/direct-release/staged/LocalOCR Studio.app. Helper hashes and verification are recorded in work/llama-build5-signature.json. This candidate is not yet notarized or installed on the Pro.

The signed helper also passed inspect, ocr, image and intelligence models, each returning exit 0 and valid JSON with the model server stopped (work/llama-build5-signed-smoke.json).

Final exact native-script reruns: scripts/build-native-tools.sh exited 0 (work/llama-build5-native.log), and scripts/smoke-native-tools.sh exited 0 (work/llama-build5-native-smoke.log), both using Xcode 27 RC.

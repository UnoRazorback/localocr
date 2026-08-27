# Local Intelligence Candidate Acceptance

## Decision

**NOT ACCEPTED — automated build/UI and manual acceptance gates remain open.**

This is implementation-readiness evidence only. It does not authorize or claim
Developer ID signing, notarization, stapling, Gatekeeper acceptance, packaging,
downloaded-package testing, second-Mac acceptance, installation, publication,
or a release version/tag.

## Candidate identity

- Candidate commit: `114518b54f68ccfa3de980da8c0964031a29862b`
- Branch: `feature/local-intelligence-mcp-faq`
- Evidence date: 2026-08-27
- Exact acceptance-check window recorded below: 2026-08-27T18:57:54Z through
  2026-08-27T18:58:21Z
- Working tree at the start of the exact-commit check: clean

## Test environment

- Mac: MacBook Air (Mac17,3), Apple M5, 24 GB RAM
- Host OS: macOS 27.0, build 26A5421a
- Developer Mode: enabled
- Xcode: stable `/Applications/Xcode.app`, Xcode 26.6 (17F113)
- macOS SDK: 26.5 (25F70)
- Swift: Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
- Required deployment target: macOS 14.0, arm64

The macOS 27 host run is development evidence, not a claim that an unpublished
macOS beta is supported for end users. Runtime Foundation Models acceptance
still requires an eligible macOS 26-or-later Mac with Apple Intelligence and
the on-device model available.

## Contract changes and TDD evidence

The candidate adds release contracts for:

- `LocalOCRIntelligence` linkage from Studio, CLI, and MCP shipping targets;
- exact macOS 14 package, app, CLI, and MCP deployment targets;
- compile-time and runtime availability guards around Foundation Models;
- absence of Network/CFNetwork imports and network/debug entitlements in
  LocalOCR shipping sources and app configuration;
- exact nine-tool MCP catalog order through a real stdio client session;
- both required helpers in the staged app contract; and
- only approved system install names and `/usr/lib/swift` RPATHs, with no
  absolute Xcode, Homebrew, user, checkout, or worktree path.

The initial repository `python3` command could not start because the selected
Homebrew Python 3.14 environment did not contain pytest. The repository virtual
environment was used instead. A focused RED run exposed the absent exact-target
and candidate-policy enforcement. One first-draft source assertion also failed
with a test-only `NameError`; that assertion was corrected before GREEN and is
not counted as product evidence.

Exact-commit focused verification:

```text
START 2026-08-27T18:57:54Z
bash -n scripts/build-native-tools.sh scripts/build-unsigned-studio-app.sh scripts/verify-direct-release.sh
.venv/bin/python -m pytest -q \
  tests/contract/test_studio_app_project.py::test_project_source_of_truth_has_exact_release_settings \
  tests/contract/test_studio_app_project.py::test_local_intelligence_is_linked_to_every_shipping_surface \
  tests/contract/test_studio_app_project.py::test_foundation_models_symbols_are_compile_and_availability_guarded \
  tests/contract/test_studio_app_project.py::test_shipping_sources_do_not_import_network_frameworks \
  tests/contract/test_studio_app_project.py::test_unsigned_build_script_has_stable_toolchain_and_confined_paths \
  tests/contract/test_direct_release_scripts.py::test_verifier_requires_arm64_and_exact_macos_14_target \
  tests/contract/test_direct_release_scripts.py::test_candidate_build_scripts_apply_local_intelligence_binary_policy \
  tests/contract/test_release_artifacts.py::test_release_artifacts_expose_only_system_dylibs_and_safe_rpaths \
  tests/contract/test_release_artifacts.py::test_release_artifacts_are_native_standalone_executables
Result: 9 passed, 0 failed, 5 existing dependency deprecation warnings
git diff --check
Result: pass, no output
END 2026-08-27T18:57:56Z
```

The real stdio test observed exactly these nine tools, in order:
`get_pdf_page_count`, `inspect_pdf`, `ocr_pdf`, `ocr_pdf_batch`, `ocr_image`,
`make_searchable_pdf`, `summarize_document`, `organize_document`, and
`extract_document_fields`.

## Complete automated matrix

| Gate | Result at exact candidate commit | Evidence |
|---|---|---|
| Clean start | PASS | `git status --short` produced no output before the focused check. |
| Script syntax | PASS | All three changed release scripts passed `bash -n`. |
| Focused release contracts | PASS | 9 passed, 0 failed. |
| `swift test` | NOT RUN | A pre-existing whole-suite process and a focused contract process already held build/UI resources. No additional build was started. |
| Direct `xcodebuild ... test` | NOT RUN | The existing Xcode UI-test child had not completed. It was not terminated, signaled, or restarted. This result is not counted. |
| `./scripts/build-native-tools.sh` | NOT RUN | Deferred to avoid overlapping the existing test/build trees. |
| `./scripts/build-unsigned-studio-app.sh` | NOT RUN | Deferred for the same resource conflict. |
| `./scripts/smoke-native-tools.sh` | NOT RUN | No exact-commit candidate artifacts were built. |
| Full `.venv/bin/python -m pytest -q` | NOT RUN | The pre-existing run remained active and was not counted as pass or failure. |
| Final clean status | OPEN | This evidence file and its report commit necessarily follow the clean candidate commit. |

No UI test was deleted, weakened, or bypassed. The waiting processes were not
modified.

## Artifact hashes and dependency inspection

At 2026-08-27T18:58:06Z, pre-existing local artifacts had these hashes:

```text
1b183af9d9affa9b679bcde9e580a91e354d38564ad2d057e1f2ed0d6fa08f0b  dist/native-tools/localocr
c71b217a74e2e98c0d18ba98b5d1e2fbb03b1cf0ea26bd66c8dcd80cc3e1b5f8  dist/native-tools/localocr-mcp
142787b539c67d1bf397f053c034cfb9a45a713b7c89c24fe26d7dd933757740  dist/unsigned-app/LocalOCR Studio.app/Contents/MacOS/LocalOCR Studio
```

Their modification times predate candidate commit `114518b`; therefore these
are diagnostic hashes only and **not accepted exact-commit candidate artifact
hashes**.

The required `otool -L` and `otool -l` inspection found:

- both native helpers report `LC_BUILD_VERSION minos 14.0`;
- all install names are Apple/system paths under `/System/Library` or
  `/usr/lib`, plus the accepted weak
  `@rpath/libswiftCompatibilitySpan.dylib` in `localocr-mcp`;
- the only reported RPATH is `/usr/lib/swift`; and
- no `/Applications/Xcode`, `/Users`, Homebrew, `/usr/local`, SwiftPM checkout,
  `.build`, or worktree path appeared.

`localocr-mcp` links Apple's system CFNetwork and Network frameworks transitively
through the MCP SDK. LocalOCR sources do not import those frameworks, the app
has no network client/server entitlement, and the product exposes stdio rather
than an HTTP listener. This dependency observation does not prove absence of a
runtime connection; that remains a manual gate.

## Manual local candidate matrix

No personal documents were used. No exact-commit app artifact was available,
so the manual matrix was not partially inferred from older builds.

| Manual gate using synthetic/project fixtures | Result |
|---|---|
| OCR while Apple Intelligence is off or unavailable | NOT RUN |
| Studio summarize, organize, and field extraction when available | NOT RUN |
| Page/evidence grounding review | NOT RUN |
| Process Another clears result and intelligence state | NOT RUN |
| Batch remains OCR-only with no intelligence actions | NOT RUN |
| Help path and client snippets | NOT RUN |
| Consent accept/revoke through Studio, CLI, and MCP | NOT RUN |
| All nine MCP tools through a configured agent client | NOT RUN manually; exact catalog listing passed automatically |
| Cancellation | NOT RUN |
| Raw source-file hash unchanged | NOT RUN |
| No network connection attributable to LocalOCR | NOT RUN |

## Known limitations and remaining acceptance work

1. Re-run the complete automated matrix from a clean exact commit after the
   existing Xcode/UI processes finish and an unlocked console is available.
2. Build fresh native and unsigned-app artifacts from that same commit; replace
   the diagnostic hashes above with exact-candidate hashes and repeat all
   dependency/RPATH scans.
3. Complete every synthetic-document manual gate on an eligible machine.
4. Investigate runtime network activity directly; static entitlements, imports,
   and dependency paths do not substitute for observation.
5. Live Foundation Models accuracy, grounding, availability, and cancellation
   need manual acceptance. Automated fixture results are not live-model proof.
6. Developer ID signing, notarization, stapling, Gatekeeper, downloaded-package,
   second-Mac, installation, version selection, tagging, and publication remain
   separate owner-authorized gates.

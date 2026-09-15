# LocalOCR 0.3.1 build 8 — source and private release acceptance

Date: 2026-09-14. Status: signed, notarized, stapled private candidate verified;
not published, installed, or accepted on the Pro/real-model target. Marketing
version remains `0.3.1`, build is `8`, and `v0.3.1-beta.1` remains a planned,
unpublished tag. The exact source, ZIP hash, notarization UUID, verification
evidence, and remaining boundaries are recorded under Task 5 below.

## Source provenance

- Build 7 source baseline: `0a62c1a64aad490fb467ac745a79d877c74f7ee6`.
- Build 8 plan: `9fd7026300abb12473502cd139260a39ccf91b05`.
- OCR row preservation: `95050c6473bebdd2e25f08a585dfdea7a4499e90`.
- Bounded GPT-OSS reasoning metadata: `354cafc08ba8c0404681b338e3612f3b7f448b4c`.
- GPT-OSS boundary hardening: `cd3bf803b53f8debe79194921b78d306bf23a00b`.
- Repeated llama locality attestation: `a7f2b454e371744e5234179742f5f7d5cb709a31`.
- Split source/release/target acceptance gates (Task 4 parent):
  `2a84c81b2c0fe93f7c29a18f1e674be77de5dd74`.
- Initial Task 4 endurance/metadata commit:
  `37909150a6b400a17aa241e20f6be6845ca4b22d`.

The initial Task 4 commit added the endurance test, build metadata, and
documentation/contract alignment. Its review fix also re-attests the approved
source inventory, isolates two test fixtures, and clarifies historical MCP
toolchain provenance. Resolve the latest record commit with
`git log -1 --format=%H -- docs/localocr-build8-acceptance-2026-09-14.md`;
the immutable artifact source commit is recorded separately under Task 5 and
must not be confused with the later acceptance-document commit.

## Synthetic fixture evidence

`Build8EnduranceAcceptanceTests` composes the real provider router, grounded
provider, OCR layout assembler, qualification service/cache, selection receipt
store, activity reporter, and secure on-disk activity ledger. The external bridge
transport is an in-process fixture: no helper/server process or model is used.
Existing qualification fixture responses exercise all three actions first, with
activity disabled for that setup. The endurance sequence then performs exactly
twenty awaited single-page equipment extractions, each requiring `$2,000.00`
with page-1 evidence `Equipment | Lift and delivery | $2,000.00`.

Each operation must add exactly one ended record and leave no active record.
The test verifies twenty bridge generation requests after qualification, twenty
unique UUID records, successful outcomes, closed/typed decoding, exactly the
17 approved `LocalAIActivityContract.v1Keys`, null runtime identifiers, and
absence of synthetic document/model/path/hash data in activity JSON. No new
production injection seam or behavior change was needed.

A forward-only elapsed counter projects into the injected activity/qualification
clock. After operations finish and heartbeat sleepers have been cancelled, it
advances exactly 600 seconds without sleeping. Cleanup preserves the twenty
recent records; reloaded selection and qualification receipts remain valid, and
the router re-discovers the unchanged synthetic identity and reports available.
Each ended timestamp is exactly 600 seconds before the injected current time.
This is deterministic synthetic idle coverage, not a real idle/server test.

SHA-256 of the exact fixture-bearing source files and canonical activity fixture:

| File | SHA-256 |
| --- | --- |
| `tests/LocalOCRIntelligenceTests/Build8EnduranceAcceptanceTests.swift` | `c58c074c430f852db51b6e8b299fc853df08f46f4237661a5dd2c9c78dfc298b` |
| `tests/LocalOCRIntelligenceTests/LocalModelQualificationServiceTests.swift` | `b5421da8129de4f937678b11f7ce5c5f3924c716c9e259d176a5e9a1d73621c3` |
| `tests/LocalOCRIntelligenceTests/LocalIntelligenceProviderRouterTests.swift` | `d427e8dbc3d1b280b34779f002c2af7d862400cc1a9a3c9561896027fe9a3a44` |
| `tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json` | `10da6abde02175ad9f1fdfbb51b656a1581b145840dd8168cdebe8ab24229114` |

The repeated `a`/`b` digest strings in the synthetic llama identity are fixture
values, not real GGUF/executable hashes or claims about Gemma/GPT-OSS.

## Task 4 commands and outcomes (historical)

```sh
swift test --filter 'Build8EnduranceAcceptanceTests|OCRLayoutTextAssemblerTests|LlamaCppBridgeAdapterTests|LlamaCppProcessProbeTests|LlamaCppQualificationTests'
python3 -m pytest -q tests/contract/test_studio_app_project.py tests/contract/test_direct_release_scripts.py tests/contract/test_beta_documentation_alignment.py
```

The focused Swift command passed **36 tests in 5 suites**, including the new
endurance test. TDD RED first left the actual reporter disconnected and produced
zero recent records/UUIDs against the required twenty; connecting the existing
reporter yielded GREEN before release metadata changed. Metadata guards were
advanced before the source metadata and correctly rejected build `7`.

The exact Python gate is broader than metadata: it also builds/stages native
artifacts. Its initial pre-metadata run returned 51 failures, 254 passes, and
16 setup errors, including the expected build-number failures, mixed SDK
linker errors, stale source-policy inventory, and absent artifact prerequisites.
The initial stable-toolchain rerun returned **13 failures, 292 passes, 16 setup
errors** in 148.20 seconds. All remaining failures/errors were in the direct
release script suite: the closed source inventory has not been re-attested for
the new source/test files, the validated release candidate is absent, and one
nonexistent-release-root test receives a different fail-closed error message.
That initial run changed no source-policy pin, release path guard, or release
toolchain check. The focused metadata/doc subset passed **11 tests**. This
initial full-gate failure is preserved rather than overwritten by later results.

Review fix round 1 re-attested the names-only source inventory using the existing
`target_source_inventory` and `canonical_json_sha256` functions. Removing exactly
`Sources/LocalOCRIntelligence/OCRLayoutTextAssembler.swift`,
`tests/LocalOCRIntelligenceTests/OCRLayoutTextAssemblerTests.swift`, and
`tests/LocalOCRIntelligenceTests/Build8EnduranceAcceptanceTests.swift` reproduces
the old pin `02afcf8e40108cd4acf1c207e59bc85d977bd566c37ab6f80756040203eaa0d2`.
The approved inventory pin is now
`3461531633aaaeb32af3268d47615fd8d986ae814d20bbf0f207432e4e18b4b5`; all policy
logic and other pins remain unchanged. The policy command passes and the
existing injected-unapproved-file test still rejects inventory drift.

The two release tests now use controlled temporary repositories: the native
publisher exercises a pinned compiler fixture despite a hostile PATH shim, and
the notarization test independently checks missing-root rejection and existing
repository-root rejection without mutation. Four targeted tests pass, including
the unchanged inventory-drift negative test. No production path guard changed.
The first post-fix full run returned 321 passes and one failure in 1173.98
seconds: an unchanged native artifact-swap test timed out at its 30-second
preparation rendezvous before reaching its safety assertions. The isolated
unmodified case reproduced in 30.44 seconds. An approved test-harness fix keeps
the helper default at 30 seconds, gives only this slow native rendezvous 120
seconds, and terminates/reaps its isolated test process group on failure.
Production timeouts, guards, and original safety assertions remain unchanged.
The narrow case then passed in 76.67 seconds. A temporary 1 ms mutation failed
at the expected assertion in 0.31 seconds and left no matching fixture
processes; the mutation was removed. All 78 MCP source-policy tests also pass.

The final exact three-file Python rerun **passed all 322 tests** in 1314.44
seconds (21:54), with five existing SWIG deprecation warnings and zero failures
or setup errors. It used the authorized normal test-only unsigned-app fixture,
without reuse/skip flags. The earlier failed runs above remain part of the record.
After that Python run, the focused Swift command was rerun with explicit stable
DEVELOPER_DIR/SDKROOT and passed all 36 tests in five suites (1.036 seconds).
The explicit outer environment uses stable Xcode, while the unchanged release
scripts still invoke their RC-pinned toolchain for that fixture. This is not
the separate Task 5 stable-toolchain candidate build.

Baseline flake preservation: before Build 8 edits the full Swift run reported
893 tests and failed in
`knownEscapedDescendantIsKilledWhenLaterRefreshAndPeerSignalFail` and
`immediateUnobservableEscapeFailsClosedWithoutClaimingContainment`. A Task 4
narrow rerun of those exact two names passed both tests (0.964 seconds).
That rerun does not replace the original failed full-suite result or a fresh
complete release-verification run.

## Toolchain and provider boundaries

Read-only local inspection found both `/Applications/Xcode.app/Contents/Developer`
with Xcode 26.6 (`17F113`) and `/Applications/Xcode-27-RC.app/Contents/Developer`
with Xcode 27.0 (`27A266a`). Scott subsequently selected the exact Xcode 27
release build for the Pro candidate. The application name is historical; its
verified `xcodebuild -version` identity is the public release build. The release
guard was moved from 26.6 to that exact path and build through failing then
passing release-toolchain contracts.
The Python command requires the existing Python
3.11.16 `.venv` from the parent checkout on PATH (default Python 3.14 has no
pytest), plus explicit Xcode 27 `DEVELOPER_DIR` and matching `SDKROOT` to avoid
mixing toolchains.

Ordinary OCR remains on-device and does not require a model server. Apple
Foundation Models, Ollama, LM Studio, and llama.cpp remain explicit separate
providers; there is no fallback, model download, or server-launch control.
The GPT-OSS reasoning exception is bound to the reviewed GGUF SHA-256
`582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`, not an alias.
It does not relax generic/Gemma closed-schema, grounding, or locality rules.

## Task 5 — verified private signed/notarized candidate

Artifact source commit: `a99f01127914cc323b2a8db2d6fa19e81bd2a476`, clean before
the distinct release build. Reviewed Task 4 starting HEAD was
`07241f33c6904a9344827a08816dc40a69c4e76a`. Task 5 source commits:

- `5c9e3961b97295f49e0592e8bf26e63739ca0ad9`: stable Xcode release pin and guides.
- `a6e057cc67d6688478287a16fa9d8695858edb86`: missed command-test expectation for
  the reviewed OCR layout-line behavior (test only).
- `5d83b4fe8992df10020a1afe3b264c9c210913f0`: current unpublished notes/guide
  expectations advanced to Build 8, retaining the version/tag.
- `a99f01127914cc323b2a8db2d6fa19e81bd2a476`: two timeout tests now establish
  bounded PID readiness and cover delayed startup; production timeouts and
  exact cleanup/error assertions remain unchanged.

All machine evidence is retained in the ignored repository-relative directory
`work/localocr-build8-acceptance/`. Each numbered log records its exact command,
source commit, stable developer/SDK paths, UTC times, and exit status. Original
failed runs are retained, not overwritten by successful reruns.

| Gate | Outcome and evidence within that directory |
| --- | --- |
| Stable pin TDD | Expected RED in `01-toolchain-red.log`; 10 focused tests passed in `02-toolchain-green.log`; current guides passed in `03-docs-green.log` and `11-docs-green.log`. All existing rejection paths retained. |
| Complete Python | 496 passed, 1 explicitly opt-in live-model skip, 5 existing SWIG warnings; `23-python-full.log`, source `5d83b4f`. The later source change touched only the two Swift test files. Initial stale-guide/missing-native-prerequisite failures remain in `10-python-full.log`; native prerequisite correction and 19 contract passes are in logs 12–13. |
| Complete Swift | 913 tests/71 suites passed on clean artifact source in `40-swift-clean-commit.log`; existing opt-in live/model/cross-app cases remain skipped. Earlier full failures remain in logs 05, 16, 18, 20, 22, and 31. The two remaining startup races were reproduced with controlled delay (33), corrected test-only (34), passed 10 repetitions (35 series), both related suites (36), and another full run (37). |
| Style/privacy/static/policy/native smoke | Passing component suites in full Swift runs; final static/native smoke and source/binary validators in logs 24–25 and 28–29. Log 26 preserves an invocation-only non-executable Python-script error; the unchanged script passed when invoked through Python. |
| Distinct unsigned Studio build | Stable Xcode build-for-testing and separate Release build passed in `42-distinct-unsigned-build.log`; Release Hardened Runtime configuration in 43. This is not a live UI/Pro acceptance run. |
| Fresh stage and pre-signing policy | Logs 44–45: version/build, identifier, exact three-helper inventory, arm64-only/minimum macOS 14.0, dependencies, RPATHs, source/binary policy, sanitized paths, and pre-signing entitlement inventory passed. |
| Signing and strict inventory | Logs 46–47: helpers signed first, app last; strict signatures for each helper, main executable, and app, correct Developer ID/team, secure timestamps, Hardened Runtime, and exact entitlements passed. |
| Notary/staple/final archive | Log 48 and `release-evidence/`: Accepted, stapled ticket validation, Gatekeeper, checksum, and script-controlled fresh extraction passed. |
| Independent archive check | Log 50 and `private-candidate/localocr-downloaded-release-evidence-20260914T230214Z-99729.txt`: checksum, path/confinement, signatures/policy, ticket, Gatekeeper, CLI/MCP 0.3.1, synthetic two-page OCR, input immutability, and temporary cleanup all passed. |
| Exact fresh extracted inventory | Log 53: physical `/private/tmp` extraction from the unchanged ZIP passed strict/deep signatures, ticket, Gatekeeper, CLI/MCP initialization, and exact per-code-object entitlements/dependencies/RPATHs. |

Final artifact: `LocalOCR-Studio-0.3.1-8.zip`.
SHA-256: `12834eed4c33042ecddb99ebd96bd2b8138a76340075d59465c38ff9ac8b09bd`.
Notarization UUID: `d045f3d8-33a2-4bfb-8217-b0165d675773`, **Accepted**;
Apple's retained log reports statusCode 0 and no issues.

Durable local private copies:

- `work/localocr-build8-acceptance/private-candidate/LocalOCR-Studio-0.3.1-8.zip`
- `work/localocr-build8-acceptance/private-candidate/LocalOCR-Studio-0.3.1-8.sha256`
- `work/localocr-build8-acceptance/release-evidence/` contains Apple submission,
  staple, Gatekeeper, checksum, and extracted-verification evidence.

The byte-identical script outputs also remain in `dist/direct-release/final/`.
The signed identifier is `com.rayconsulting.localocr`, version `0.3.1`, build
`8`, with exactly `localocr`, `localocr-mcp`, and `localocr-model-bridge` helpers.
Every executable is arm64 and targets macOS 14.0. Developer ID team is
`DZ8B5454ZN`. The only producer entitlement is the approved Local AI Activity
application group on CLI, MCP, and main/app; the bridge has no entitlements.
No debug entitlement or additional exception was allowed. Absolute Xcode
RPATHs and non-system dependency paths were rejected.

Preserved environmental failure: log 51 records an additional extraction into
the synced Documents evidence workspace failing strict app codesign because
File Provider added `com.apple.FinderInfo`/`com.apple.fileprovider.fpfs#P` to the
app directory. Read-only metadata evidence is log 52. That failed extraction
remains unchanged at `work/localocr-build8-acceptance/fresh-extracted.FKzWnZ/`.
The parent independently reproduced the destination effect. The authorized
controlled `/private/tmp` rerun (53) from the identical SHA-256 had only
provenance metadata and passed every exact check without stripping attributes,
re-signing, or rebuilding. This is a destination-metadata environmental failure,
not an archive defect; it does not replace or hide the failed result.

## Remaining target-machine and release decisions

- This record authorizes no publication, installation, merge, or push. The
  private candidate is not a live UI, real-model, or controlled Pro acceptance.
- Controlled Pro macOS 27 GR run: record `sw_vers`, architecture, exact app
  version/build, archive SHA-256, signature/ticket/Gatekeeper, and all three
  helpers. A local `27.0` version string or upgrade statement is not that gate.
- Two consecutive Gemma Q8 qualifications and two consecutive GPT-OSS 120B
  qualifications, plus two consecutive six-operation real-model synthetic
  harnesses. Equipment must be `$2,000.00`, grounded to page 1.
- Twenty sequential real-model operations, then a real ten-minute idle with
  unchanged PID, alias, fingerprint, and listener; selected/available/qualified
  afterward; exactly one readable 17-key record per generation.
- Pro owner controls server launch and OS upgrade/reboot. Delivery must use an
  authenticated route; do not bypass the changed SSH host key. Preserve only
  synthetic outputs and content-free real-document timing/SHA evidence.

Fixture success and build output are not Gemma/GPT acceptance, installation,
publication, or permission to process/share private business documents.

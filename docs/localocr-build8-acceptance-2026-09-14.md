# LocalOCR 0.3.1 build 8 — source acceptance record

Date: 2026-09-14. Status: private candidate source verification only, not a
published release or real-model acceptance. Marketing version remains `0.3.1`,
build is `8`, and `v0.3.1-beta.1` remains a planned, unpublished tag. Planned
assets are `LocalOCR-Studio-0.3.1-8.zip` and `.sha256`; no ZIP hash, signing,
notarization, installation, or target acceptance is claimed here.

## Source provenance

- Build 7 source baseline: `0a62c1a64aad490fb467ac745a79d877c74f7ee6`.
- Build 8 plan: `9fd7026300abb12473502cd139260a39ccf91b05`.
- OCR row preservation: `95050c6473bebdd2e25f08a585dfdea7a4499e90`.
- Bounded GPT-OSS reasoning metadata: `354cafc08ba8c0404681b338e3612f3b7f448b4c`.
- GPT-OSS boundary hardening: `cd3bf803b53f8debe79194921b78d306bf23a00b`.
- Repeated llama locality attestation: `a7f2b454e371744e5234179742f5f7d5cb709a31`.
- Split source/release/target acceptance gates (Task 4 parent):
  `2a84c81b2c0fe93f7c29a18f1e674be77de5dd74`.

The source commit containing this record adds only the endurance test, build
metadata, and documentation/contract alignment. Resolve it with
`git log -1 --format=%H -- docs/localocr-build8-acceptance-2026-09-14.md`;
the final immutable release commit must be recorded separately when building.

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

## Commands and outcomes

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
The final stable-toolchain rerun returned **13 failures, 292 passes, 16 setup
errors** in 148.20 seconds. All remaining failures/errors were in the direct
release script suite: the closed source inventory has not been re-attested for
the new source/test files, the validated release candidate is absent, and one
nonexistent-release-root test receives a different fail-closed error message.
No source-policy pin, release path guard, or release toolchain check was changed
or bypassed. The focused metadata/doc subset passed **11 tests**. The full gate
is **NOT PASSED** and must be rerun after release prerequisites are reconciled.

Baseline flake preservation: before Build 8 edits the full Swift run reported
893 tests and failed in
`knownEscapedDescendantIsKilledWhenLaterRefreshAndPeerSignalFail` and
`immediateUnobservableEscapeFailsClosedWithoutClaimingContainment`. A Task 4
narrow rerun of those exact two names passed both tests (0.964 seconds).
That rerun does not replace the original failed full-suite result or a fresh
complete release-verification run.

## Toolchain and provider boundaries

Read-only local inspection found `/Applications/Xcode.app/Contents/Developer`,
stable Xcode 26.6 (`17F113`), its `MacOSX26.5.sdk`, and macOS 27.0 build `26A428`.
The release scripts still pin Xcode 27 RC (`27A266a`); reconciling that pin with
the stable release requirement is a pending release-verification gate, not an
implicit toolchain switch. The Python command requires the existing Python
3.11.16 `.venv` from the parent checkout on PATH (default Python 3.14 has no
pytest), plus explicit stable `DEVELOPER_DIR` and matching `SDKROOT` to avoid
mixing an older linker with the Command Line Tools macOS 27 SDK.

Ordinary OCR remains on-device and does not require a model server. Apple
Foundation Models, Ollama, LM Studio, and llama.cpp remain explicit separate
providers; there is no fallback, model download, or server-launch control.
The GPT-OSS reasoning exception is bound to the reviewed GGUF SHA-256
`582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`, not an alias.
It does not relax generic/Gemma closed-schema, grounding, or locality rules.

## Remaining release and target-machine gates

- Fresh complete Swift/Python, policy/privacy, native-helper, smoke, and Studio
  verification under the stable toolchain; retain original failures and narrow
  reruns separately. Reconcile source inventory/toolchain pins without bypasses.
- Immutable unsigned build, exact version/build and helper inventory, then
  separate signing, notarization, stapling, Gatekeeper, extracted-archive,
  dependency/RPATH, and checksum verification. No publication is authorized by
  this record.
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

# Task 7 report — shared Local Intelligence CLI commands

## Commits and scope

- Base: `dc767deaacd98f19301a98cf800396c14934793b`
- CLI implementation and tests: `1854dbfdb76bc4437b9bd40c63302085f56f42c1`
- Scope: Task 7 only. No Studio, MCP authority, provider-management, packaging,
  signing, documentation, publication, or live harness state changed.

Implementation files:

- `Sources/LocalOCRCommandKit/CLIArgumentSurface.swift`
- `Sources/LocalOCRCommandKit/CLIApplication.swift`
- `Sources/LocalOCRCommandKit/ConsentCommandIO.swift`
- `Sources/LocalOCRCLIExecutable/main.swift`
- `tests/LocalOCRCommandKitTests/CLITestSupport.swift`
- `tests/LocalOCRCommandKitTests/CLIApplicationTests.swift`
- `tests/LocalOCRCommandKitTests/CLIArgumentSurfaceTests.swift`

This report is the only follow-up file outside that seven-file implementation
commit.

## TDD evidence

Genuine RED was captured before each production behavior:

1. Parser RED: `intelligence models` failed as unexpected extra values because
   the `intelligence` group did not exist.
2. Application injection RED: the test harness failed to compile with
   `extra arguments at positions #5, #6` because `CLIApplication` had no
   `LocalIntelligenceManaging` or deterministic clock injection.
3. Behavior RED: 42 expected issues covered the then-unimplemented test,
   select, status, reset, prompt, receipt, and exit-code paths.
4. Determinism/status RED: nine expected issues proved manager-order output was
   unstable and provider-unavailable status omitted its exact provider.

Final GREEN counts:

- Focused parser/application: 49/49.
- Full `LocalOCRCommandKitTests`: 50/50.
- Full `LocalOCRIntelligenceTests`: 187/187, with one intentional opt-in live
  Foundation Models smoke skip.
- Full Swift package: 721/721 across 50 suites.

The first full-package attempt reproduced the ledger's existing host-load
deadline sensitivity in five unchanged bridge/loopback timing assertions. The
immediate fresh rerun of the exact required `swift test --quiet` command passed
721/721 in 6.261 seconds. No Task 7 test failed in either run.

## Command and help contracts

Exactly these commands were added:

```text
localocr intelligence models
localocr intelligence test <provider> <model>
localocr intelligence select <provider> <model>
localocr intelligence status
localocr intelligence reset
```

`models`, `test`, `status`, and `reset` accept `--json`. `select` accepts no
flags; parser and application tests reject `--json`, `--yes`, `--force`, and
`--noninteractive`. Install, pull, delete, start, stop, load, unload, and
configure commands remain absent.

Root, group, and leaf help expose these exact usage lines:

```text
Usage: localocr intelligence <models|test|select|status|reset>
Usage: localocr intelligence models [--json]
Usage: localocr intelligence test <provider> <model> [--json]
Usage: localocr intelligence select <provider> <model>
Usage: localocr intelligence status [--json]
Usage: localocr intelligence reset [--json]
```

The Apple spelling is derived from the exact Task 6 descriptor rather than a
new identity:

```text
apple_foundation_models SystemLanguageModel.default
```

Models text is a deterministic tabular contract with provider, model,
fingerprint, harness version, display name, locality, locality reason,
qualification, availability, and selection. Models JSON contains the same
metadata under a sorted `models` array. Qualification text/JSON reports exact
identity, status, failures, qualified timestamp, policy, fixture version, and
sorted passed actions. Status text/JSON reports none, selected, or invalid
state with current/stale qualification and acknowledgment metadata. Reset emits
`reset` or `{"state":"reset"}` and is idempotent.

## Acknowledgment and identity review

External selection prints the approved four-line disclosure verbatim, requires
a real terminal, and accepts only exact lowercase `y` or `yes`. Tests reject
nonterminal input, EOF, nil, empty, uppercase, mixed case, leading/trailing
whitespace, embedded newlines, a queued extra line, `n`, and `no`, with zero
selection mutation. Standard input uses bounded one-byte reads so a second
queued line remains observable and fails closed.

Selection resolves exactly one current descriptor, rejects missing or duplicate
matches, and refuses unavailable, blocked, unverified, failed, stale, or
untested external candidates before prompting. The accepted timestamp and exact
descriptor identity are passed together to `selectExternal`; a manager-reported
identity race returns exit 2 without persistence. Apple selection uses the
exact system descriptor and never prompts.

## Exit-code matrix

| Exit | Meaning |
|---:|---|
| 0 | Successful models, passed test, selection, valid status, or reset |
| 2 | Invalid arguments; missing/ambiguous/unavailable/unsafe/unqualified model; invalid selection state; required or declined acknowledgment |
| 4 | Swift cancellation, LocalOCR cancellation, or stable Intelligence cancellation |
| 1 | Helper, store, protocol, generation, context, schema, grounding, or other operational failure |

All committed `IntelligenceError` and `LocalIntelligenceSelectionFailure` cases
are mapped by exhaustive switches; operational errors are not converted to
argument failures.

## Laziness and privacy/security review

- The executable constructs `LocalIntelligenceEnvironment.live` with only
  `RelativeModelBridgeExecutableLocator`; it neither searches `PATH` nor
  resolves or launches the helper during construction.
- A recording-locator test proved construction plus `--help`, `--version`, and
  ordinary OCR kept resolution count at zero. Only `intelligence models`
  resolved the fake locator, exactly once per approved external provider.
- `models`, `status`, and `reset` pass no document or prompt data. `test` calls
  the manager with only the exact content-free descriptor; Task 6 owns the
  immutable synthetic fixture.
- Text output strips control characters; JSON is sorted-key encoded. No OCR
  text, filenames, paths, prompts, model output, credentials, or secrets are
  included in the new contracts.
- Reset calls only the model manager's reset boundary. Tests prove it does not
  read or revoke MCP consent and does not invoke qualification or harness
  management.
- Existing OCR options, progress, batch exit behavior, MCP consent behavior,
  help, version, and output contracts remain covered and green.
- No live Apple, Ollama, or LM Studio provider was invoked. All new manager and
  locator tests are deterministic fixtures.

## Concerns

No remaining Task 7 correctness or privacy blocker was found. The one observed
full-suite timing failure is the pre-existing host-load sensitivity already
recorded in the Task 6 ledger; the required exact command passed on the fresh
rerun without code or assertion changes.

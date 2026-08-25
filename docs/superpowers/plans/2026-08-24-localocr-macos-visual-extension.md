# LocalOCR macOS Visual Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the approved LocalOCR identity into the existing desktop-native single-document and batch workspaces without changing engine behavior or privacy contracts.

**Architecture:** Introduce semantic macOS design tokens and reusable identity/status components inside `LocalOCRStudioKit`, then adopt them in existing views. Preserve `StudioViewModel`, document actions, batch coordinator, CLI, MCP, and service interfaces unchanged.

**Tech Stack:** Swift 6, SwiftUI for macOS, AppKit panels, Swift Testing, XCUITest

**Spec:** `docs/superpowers/specs/2026-08-24-localocr-macos-visual-extension.md`

## Global Constraints

- Preserve the open-core engine, CLI, MCP, and service interfaces.
- Preserve local-only processing and content-free diagnostics.
- Preserve every single/batch cancellation and lifecycle guarantee.
- Do not modify or remove unrelated untracked files.
- Every behavior change starts with a failing test.

---

### Task 1: macOS semantic design system

**Files:**
- Create: `Sources/LocalOCRStudioKit/LocalOCRStudioTheme.swift`
- Test: `tests/LocalOCRStudioKitTests/StudioVisualContractTests.swift`

**Interfaces:**
- Produces: `LocalOCRStudioPalette`, `LocalOCRStudioMetrics`, `StudioCornerMark`, and `StudioOnDeviceBadge`.

- [ ] Add failing tests for shared token values, compact Corner behavior, and privacy-badge copy.
- [ ] Run `swift test --filter StudioVisualContractTests` and verify RED.
- [ ] Implement the semantic tokens and components without importing network or document data.
- [ ] Re-run the focused tests and verify GREEN.

### Task 2: Single-document workspace extension

**Files:**
- Modify: `Sources/LocalOCRStudioKit/LocalOCRStudioView.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioDropZoneView.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioStatusViews.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioResultView.swift`
- Test: `tests/LocalOCRStudioKitTests/StudioViewContractTests.swift`

**Interfaces:**
- Consumes: Task 1 components.
- Produces: branded empty, processing, result, and failure states with unchanged actions.

- [ ] Add failing contract tests for LocalOCR identity, on-device status, action hierarchy, and accessibility labels.
- [ ] Run focused tests and verify RED.
- [ ] Restyle the existing workspace without moving workflow authority out of `StudioViewModel`.
- [ ] Re-run focused tests and verify GREEN.

### Task 3: Batch workspace extension

**Files:**
- Modify: `Sources/LocalOCRStudioKit/BatchWorkspaceView.swift`
- Modify: `Sources/LocalOCRStudioKit/BatchStatusViews.swift`
- Test: `tests/LocalOCRStudioKitTests/BatchViewContractTests.swift`

**Interfaces:**
- Consumes: Task 1 components.
- Produces: branded intake, review, processing, completion, and partial-failure states with unchanged coordinator behavior.

- [ ] Add failing tests for queue-state visual semantics, privacy-safe diagnostics, and accessible action hierarchy.
- [ ] Run focused tests and verify RED.
- [ ] Apply the shared design language to batch views while preserving stable row identity and cancellation.
- [ ] Re-run focused tests and verify GREEN.

### Task 4: App identity, dark appearance, and acceptance

**Files:**
- Modify: `App/LocalOCRStudioApp.swift`
- Modify: `AppUITests/LocalOCRStudioUITests.swift`
- Modify: `docs/superpowers/plans/2026-08-21-localocr-desktop-batch-beta2.md`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: window-level identity, dark/high-contrast UI coverage, and updated release gates.

- [ ] Add failing UI assertions for the Corner mark, on-device badge, empty workspace, single result, batch workspace, dark appearance, and keyboard accessibility.
- [ ] Run the affected UI tests and verify RED.
- [ ] Wire final app-level styling and accessibility identifiers.
- [ ] Run `swift test`, affected app UI tests on an uncontended host, and the content/privacy contract suites.
- [ ] Record any remaining manual appearance, signing, packaging, and release gates.

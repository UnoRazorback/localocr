# LocalOCR Studio process-another-document design

**Date:** 2026-08-06  
**Status:** Owner-approved design  
**Scope:** LocalOCR Studio desktop results workflow only

## Problem

After LocalOCR Studio finishes OCR, the results screen offers Copy, Save Text,
and, for PDFs, Create Searchable PDF. It does not provide a visible way to
return to the empty drop/open screen. A user currently has to close and reopen
the window or quit and relaunch the app before processing another document.

## User outcome

From any successful PDF or image result, the user can select **Process Another
Document** and immediately return to the original empty screen, ready to drop
or open one new local document.

## Interface design

Add a secondary **Process Another Document** button to the lower-left of the
result card footer. Keep Copy, Save Text, and Create Searchable PDF grouped on
the right.

The button:

- appears for both PDF and image results;
- is discoverable through the accessibility tree with the stable identifier
  `studio.process-another`;
- immediately clears the current result without a confirmation dialog;
- does not modify or delete the source document or any previously saved output;
  and
- is disabled while searchable-PDF creation is active, matching the existing
  result-footer action lock.

No File-menu-only or header-only replacement is included. Those placements are
less discoverable than a visible footer action and are unnecessary for this
beta.

## Behavior and state

The result action delegates to the existing `StudioViewModel.clear()` behavior.
That operation cancels any model-owned processing task, invalidates retry state,
removes the current source/result reference, and returns the model to `.empty`.

`LocalOCRStudioView` must also invalidate view-owned searchable-PDF lifecycle
state before clearing:

- cancel and release any searchable-PDF task;
- clear searchable progress and action errors; and
- reset the searchable-PDF busy flag.

Under the normal interface the action cannot be invoked during
searchable-PDF creation because the result footer is disabled. The lifecycle
cleanup remains explicit so programmatic or future callers cannot leave stale
state behind.

## Error and data handling

The reset action cannot fail and presents no alert. Unsaved recognized text is
discarded from the view immediately, but the source document remains unchanged
and can be reopened. Saved text and searchable-PDF files remain at their chosen
destinations.

The feature does not change OCR, CLI, MCP, signing, notarization, privacy, file
format, or compatibility contracts.

## Verification

Test-first coverage must prove:

1. Result-state contracts expose the process-another action for both PDF and
   image results, while empty, processing, and failure states do not.
2. Invoking the result reset returns the model to `.empty` and removes the
   retry/source reference.
3. The result view contains the visible label and stable accessibility
   identifier.
4. Existing result actions and searchable-PDF busy-state disabling remain
   intact.
5. The focused Studio tests, full Swift suite, full Python contract suite, and
   release-script lint checks pass.
6. A freshly signed and notarized candidate returns directly from a real result
   to the empty drop screen on both the build Mac and Mac mini.

## Release impact

Because this changes shipped app behavior after Beta Candidate 1 was signed,
the change requires a reviewed merge followed by a fresh exact-commit Release
build, helper-first signing, notarization, stapling, GitHub draft asset
replacement, build-Mac redownload verification, and Mac mini acceptance. The
private beta must remain unpublished until those gates pass and the owner
explicitly approves publication.

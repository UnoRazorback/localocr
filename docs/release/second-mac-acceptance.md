# LocalOCR Studio second-Mac acceptance

This is an uncompleted acceptance template, not a release approval. The release
owner chooses the second Mac and tester. Publication or promotion remains
blocked until a completed copy from that Mac records an overall `PASS`.

- Release version:
- Build:
- Release commit:
- Download URL:
- ZIP SHA-256:
- Test date and time:
- Mac model:
- Processor:
- macOS version:
- Gatekeeper result:
- Stapled ticket result:
- App launch result:
- CLI version result:
- MCP initialization result:
- OCR smoke input type:
- OCR smoke result:
- Tester:
- Overall result: PASS or FAIL

## Tester procedure

1. Download the final ZIP and published SHA-256 file through the same URL that
   will be given to testers. Do not reuse a staging or build artifact.
2. Set `LOCALOCR_RELEASE_VERSION` to the expected release version. Run
   `scripts/test-downloaded-release.sh` with exactly the absolute downloaded ZIP
   path and absolute checksum-file path.
3. Optionally set `LOCALOCR_SMOKE_INPUT` to an explicit local PDF or
   macOS Vision-decodable image fixture before running the script. The verifier
   will not discover or select a document on its own.
4. Launch the freshly extracted app, exercise one PDF and one
   macOS Vision-decodable image, create a searchable PDF, confirm both source
   files are unchanged, and quit the app cleanly.
5. Transfer the script evidence file and this completed record to the private
   release-evidence location selected by the owner.

Do not commit a completed copy containing tester or personal machine
identifiers unless the owner explicitly approves it. Do not replace the final
field with `PASS` unless every required check passed on the selected second Mac.

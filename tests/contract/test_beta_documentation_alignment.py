import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
VERSION = "0.3.1"
BUILD = "7"
TAG = "v0.3.1-beta.1"
FILES = {
    "readme": ROOT / "README.md",
    "studio": ROOT / "docs/studio.md",
    "mcp": ROOT / "docs/mcp.md",
    "cli": ROOT / "docs/cli.md",
}
LOCAL_AI_ACTIVITY_GATE = ROOT / "docs/release/local-ai-activity-entitlement-gate.md"
LOCAL_AI_ACTIVITY_TRUTHS = (
    "App reported",
    "Nonparticipating apps are not visible",
    "No per-app Neural Engine utilization metric is available",
    "Activity sharing is content-free",
    "Vision OCR does not create a Local AI Activity record",
    "Active leases expire after 45 seconds",
    "Recent activity expires within 24 hours",
    "iOS background delivery is opportunistic, not continuous",
)


def test_repository_docs_link_to_beta_guide():
    assert "BETA_TESTING.md" in FILES["readme"].read_text()
    assert "../BETA_TESTING.md" in FILES["studio"].read_text()
    assert "../BETA_TESTING.md" in FILES["mcp"].read_text()


def test_readme_and_studio_describe_beta_2_1_candidate_and_reset():
    for key in ("readme", "studio"):
        text = FILES[key].read_text()
        prose = " ".join(text.split())
        assert VERSION in text
        assert f"build `{BUILD}`" in prose
        assert TAG in text
        assert "release candidate" in text.lower()
        assert "no published Beta 2.1 download is claimed" in prose or "no Beta 2.1 download is being claimed" in prose
        assert "Process Another Document" in text
        assert "Xcode 27 RC (`27A266a`)" in prose
        assert "Xcode 26.6" not in text
        assert DEPLOYMENT_TARGET in prose
        assert "Future Apple beta compatibility is not guaranteed" in prose


def test_mcp_guide_has_installed_helper_and_verified_client_commands():
    text = FILES["mcp"].read_text()
    assert "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp" in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio --scope local localocr --" in text
    assert "https://learn.chatgpt.com/docs/extend/mcp" in text
    assert "https://code.claude.com/docs/en/mcp" in text
    assert "requires a separate confirmation" in text
    assert "Generic clients remain" in text and "copy-only" in text


def test_current_docs_align_on_beta_2_1_providers_help_and_helpers():
    for path in (*FILES.values(), ROOT / "BETA_TESTING.md"):
        text = path.read_text()
        prose = " ".join(text.split())
        if path.name in {"README.md", "studio.md", "mcp.md", "BETA_TESTING.md"}:
            assert "Ollama" in text
            assert "LM Studio" in text
            assert "never silently switches" in prose
    readme = FILES["readme"].read_text()
    assert "localocr-model-bridge" in readme
    assert "offline Help" in readme


def test_desktop_first_docs_point_to_one_canonical_advanced_setup():
    for key in ("readme", "studio"):
        text = FILES[key].read_text()
        assert "docs/mcp.md#advanced-setup" in text or "mcp.md#advanced-setup" in text

    beta = (ROOT / "BETA_TESTING.md").read_text()
    assert "docs/mcp.md#advanced-setup" in beta


def test_cli_and_mcp_docs_align_on_consent_management():
    cli_text = FILES["cli"].read_text()
    mcp_text = FILES["mcp"].read_text()
    installed_cli = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr"
    for operation in ("status", "accept", "revoke"):
        assert f"localocr mcp-consent {operation}" in cli_text
        assert f'"{installed_cli}" mcp-consent {operation}' in mcp_text


def test_local_ai_activity_docs_state_required_truths_and_controls():
    docs = {key: path.read_text() for key, path in FILES.items()}
    corpus = " ".join("\n".join(docs.values()).split())

    for truth in LOCAL_AI_ACTIVITY_TRUTHS:
        assert truth in corpus
    for text in docs.values():
        assert "Local AI Activity" in text

    assert "Operations continue if activity sharing is unavailable" in corpus
    assert "clear recent activity in the reader" in corpus
    assert "explicitly injected development ledgers" in corpus
    assert "rather than the official group" in corpus

    mcp = docs["mcp"]
    assert (
        "The content-free activity ledger does not prevent an MCP client from "
        "separately sending OCR inputs or results to its chosen provider"
    ) in " ".join(mcp.split())


def test_local_ai_activity_entitlement_gate_records_authorized_configuration_and_pending_evidence():
    gate = LOCAL_AI_ACTIVITY_GATE.read_text()
    prose = " ".join(gate.split())
    for required in (
        "DZ8B5454ZN.com.rayconsulting.local-ai-activity",
        "com.rayconsulting.local-ai-activity.changed",
        "LocalOCR Studio", "Contents/Helpers/localocr-mcp", "Contents/Helpers/localocr",
        "signature", "entitlement", "container", "nested helpers first and the containing app last",
        "17-key", "runtime_identifier", "unsigned", "pending",
        "localocr-model-bridge", "iOS", "publication",
    ):
        assert required in prose
    assert "blocked pending the approvals below" not in gate


def test_private_build_7_candidate_identity_and_suite_boundary():
    for name in ("README.md", "docs/studio.md", "BETA_TESTING.md"):
        text = (ROOT / name).read_text()
        assert f"LocalOCR-Studio-{VERSION}-{BUILD}.zip" in text
        assert "LocalOCR-Studio-0.3.1-4" not in text
    readme = FILES["readme"].read_text()
    assert "private integration release candidate" in readme
    assert "not a published download" in readme
    for requirement in ("llama_cpp", "summarize", "organize", "extract-fields",
                        "Local AI Activity", "Ordinary OCR works without a model server"):
        assert requirement in readme
    for name in ("README.md", "docs/studio.md", "docs/mcp.md", "BETA_TESTING.md"):
        text = (ROOT / name).read_text()
        assert "27A266a" in text
        assert "17F113" not in text

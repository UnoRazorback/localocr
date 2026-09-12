from pathlib import Path
import re

import pytest


ROOT = Path(__file__).resolve().parents[2]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def mask_comments_and_strings(source: str) -> str:
    masked = list(source)
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            while index < len(source) and source[index] != "\n":
                masked[index] = " "
                index += 1
            continue
        if source.startswith("/*", index):
            depth = 0
            while index < len(source):
                if source.startswith("/*", index):
                    depth += 1
                    masked[index:index + 2] = [" ", " "]
                    index += 2
                    continue
                if source.startswith("*/", index):
                    depth -= 1
                    masked[index:index + 2] = [" ", " "]
                    index += 2
                    if depth == 0:
                        break
                    continue
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            continue
        if source.startswith('"""', index):
            masked[index:index + 3] = [" ", " ", " "]
            index += 3
            while index < len(source) and not source.startswith('"""', index):
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            if index < len(source):
                masked[index:index + 3] = [" ", " ", " "]
                index += 3
            continue
        if source[index] == '"':
            masked[index] = " "
            index += 1
            while index < len(source):
                if source[index] == "\n":
                    break
                masked[index] = " "
                if source[index] == '"' and source[index - 1] != "\\":
                    index += 1
                    break
                index += 1
            continue
        index += 1
    return "".join(masked)


def live_call_arguments(source: str) -> list[str]:
    code = mask_comments_and_strings(source)
    needle = "LocalIntelligenceEnvironment.live"
    calls: list[str] = []
    search_from = 0
    while (start := code.find(needle, search_from)) != -1:
        if start > 0 and (code[start - 1].isalnum() or code[start - 1] == "_"):
            search_from = start + len(needle)
            continue
        qualifier = start - 1
        while qualifier >= 0 and code[qualifier].isspace():
            qualifier -= 1
        if qualifier >= 0 and code[qualifier] == ".":
            search_from = start + len(needle)
            continue
        opening = start + len(needle)
        while opening < len(code) and code[opening].isspace():
            opening += 1
        if opening >= len(code) or code[opening] != "(":
            search_from = start + len(needle)
            continue

        depth = 0
        for index in range(opening, len(code)):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    calls.append(code[opening + 1:index])
                    search_from = index + 1
                    break
        else:
            raise AssertionError("unterminated LocalIntelligenceEnvironment.live invocation")
    return calls


def top_level_arguments(arguments: str) -> list[str]:
    result: list[str] = []
    start = 0
    stack: list[str] = []
    matching = {")": "(", "]": "[", "}": "{"}
    for index, character in enumerate(arguments):
        if character in "([{":
            stack.append(character)
        elif character in ")]}" and stack:
            assert stack.pop() == matching[character]
        elif character == "," and not stack:
            result.append(arguments[start:index].strip())
            start = index + 1
    final = arguments[start:].strip()
    if final:
        result.append(final)
    return result


def assert_target_live_call(source: str, role: str) -> None:
    calls = live_call_arguments(source)
    assert len(calls) == 1, "official target must contain exactly one live environment invocation"
    arguments = top_level_arguments(calls[0])
    labeled = {
        match.group(1): argument
        for argument in arguments
        if (match := re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:", argument))
    }
    assert re.fullmatch(
        r"activityReporter\s*:\s*LocalAIActivityProduction\.makeReporter\(\)",
        labeled.get("activityReporter", ""),
    ), "official targets must use the approved production reporter factory"
    producer_roles = [
        argument for argument in arguments if re.match(r"^producerRole\s*:", argument)
    ]
    assert len(producer_roles) == 1
    assert re.fullmatch(
        rf"producerRole\s*:\s*{re.escape(role)}",
        producer_roles[0],
    )


def test_role_text_in_a_comment_cannot_qualify_a_legacy_live_call() -> None:
    source = """
        // producerRole: .studio
        let environment = LocalIntelligenceEnvironment.live(
            bridgeLocator: RelativeModelBridgeExecutableLocator()
        )
    """

    with pytest.raises(AssertionError):
        assert_target_live_call(source, ".studio")


def test_official_live_call_rejects_an_unapproved_activity_reporter() -> None:
    source = """
        let environment = LocalIntelligenceEnvironment.live(
            bridgeLocator: RelativeModelBridgeExecutableLocator(),
            producerRole: .studio,
            activityReporter: TemporaryReporter()
        )
    """

    with pytest.raises(AssertionError):
        assert_target_live_call(source, ".studio")


def test_similarly_named_type_is_not_the_official_live_invocation() -> None:
    source = """
        let environment = FakeLocalIntelligenceEnvironment.live(
            bridgeLocator: RelativeModelBridgeExecutableLocator(),
            producerRole: .studio
        )
    """

    with pytest.raises(AssertionError):
        assert_target_live_call(source, ".studio")


def test_qualified_fake_type_is_not_the_unqualified_official_live_invocation() -> None:
    source = """
        let environment = Shadow.LocalIntelligenceEnvironment.live(
            bridgeLocator: RelativeModelBridgeExecutableLocator(),
            producerRole: .studio
        )
    """

    with pytest.raises(AssertionError):
        assert_target_live_call(source, ".studio")


def test_each_official_target_declares_one_exact_producer_role() -> None:
    expected_roles = {
        "App/LocalOCRStudioApp.swift": ".studio",
        "Sources/LocalOCRMCPExecutable/main.swift": ".mcp",
        "Sources/LocalOCRCLIExecutable/main.swift": ".cli",
    }

    for path, role in expected_roles.items():
        assert_target_live_call(read(path), role)

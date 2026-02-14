from tools import TOOL_DEFINITIONS, TOOL_HANDLERS


def test_tool_registry_contains_expected_tools() -> None:
    names = [tool["function"]["name"] for tool in TOOL_DEFINITIONS]
    assert "push_widget" in names
    assert "read_screenshot" in names
    assert "read_transcript" in names
    assert "run_bash" in names
    assert "web_search" in names

    assert "push_widget" in TOOL_HANDLERS
    assert "read_screenshot" in TOOL_HANDLERS
    assert "read_transcript" in TOOL_HANDLERS
    assert "run_bash" in TOOL_HANDLERS
    assert "web_search" in TOOL_HANDLERS

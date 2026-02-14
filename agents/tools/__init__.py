from __future__ import annotations

from .widget import PUSH_WIDGET_TOOL, handle_push_widget
from .screenshot import READ_SCREENSHOT_TOOL, handle_read_screenshot
from .transcript import READ_TRANSCRIPT_TOOL, handle_read_transcript
from .bash import RUN_BASH_TOOL, handle_run_bash
from .web_search import WEB_SEARCH_TOOL, handle_web_search

TOOL_DEFINITIONS = [
    PUSH_WIDGET_TOOL,
    READ_SCREENSHOT_TOOL,
    READ_TRANSCRIPT_TOOL,
    RUN_BASH_TOOL,
    WEB_SEARCH_TOOL,
]

TOOL_HANDLERS = {
    "push_widget": handle_push_widget,
    "read_screenshot": handle_read_screenshot,
    "read_transcript": handle_read_transcript,
    "run_bash": handle_run_bash,
    "web_search": handle_web_search,
}

from __future__ import annotations

from tools.widget import PUSH_WIDGET_TOOL, handle_push_widget
from tools.screenshot import READ_SCREENSHOT_TOOL, handle_read_screenshot

TOOL_DEFINITIONS = [PUSH_WIDGET_TOOL, READ_SCREENSHOT_TOOL]

TOOL_HANDLERS = {
    "push_widget": handle_push_widget,
    "read_screenshot": handle_read_screenshot,
}

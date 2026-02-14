from __future__ import annotations

PUSH_WIDGET_TOOL = {
    "type": "function",
    "function": {
        "name": "push_widget",
        "description": "Push an HTML widget to a target device. The widget will be rendered on the device's canvas.",
        "parameters": {
            "type": "object",
            "properties": {
                "html": {
                    "type": "string",
                    "description": "The HTML content of the widget to render.",
                },
                "target": {
                    "type": "string",
                    "enum": ["ipad", "mac"],
                    "description": "The target device to display the widget on.",
                },
                "widget_id": {
                    "type": "string",
                    "description": "A unique identifier for this widget. Use a descriptive slug.",
                },
            },
            "required": ["html", "target", "widget_id"],
        },
    },
}


def handle_push_widget(
    arguments: dict, context: dict
) -> tuple[str, dict]:
    html = arguments["html"]
    target = arguments["target"]
    widget_id = arguments["widget_id"]

    widget = {
        "widget_id": widget_id,
        "target": target,
        "html": html,
    }

    context.setdefault("widgets", []).append(widget)

    return f"Widget '{widget_id}' pushed to {target}.", widget

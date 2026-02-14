"""Stateless GPT-5.2 wrapper with push_widget tool."""
from __future__ import annotations

import json
from openai import OpenAI

client = OpenAI()

DEFAULT_MODEL = "gpt-5.2"
MAX_TOOL_ROUNDS = 6

SYSTEM_PROMPT = """\
You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can push interactive HTML widgets to devices using the push_widget tool.

## Widget Design Standards

When creating widgets, produce premium, polished UI — not plain utility HTML.

**Required style:**
- Dark theme base: deep backgrounds (#0a0a0e / #0f0f14), light text (rgba 255,255,255,0.88)
- Layered depth: atmospheric gradient backgrounds + translucent cards with backdrop-filter + soft borders
- Clear hierarchy: bold headlines, secondary metadata in muted tones, tertiary labels subtle
- Spacing rhythm: 12/16/24px, generous padding, never cramped
- Rounded geometry: 12-20px card radii, consistent corner language
- Accent color: violet (#8b5cf6) for highlights, links, progress, badges
- Componentized layouts: hero panel + metric cards, not one dense block of text
- Visual accents: status pills, progress bars, icon chips, KPI numbers when relevant

**CSS pattern:** Define tokens in :root, compose classes like .panel, .metric, .badge, .kpi.
Keep widgets self-contained (inline CSS/JS, no external frameworks).\
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "push_widget",
            "description": (
                "Push an HTML widget to a target device. "
                "The widget will be rendered on the device's canvas."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "html": {
                        "type": "string",
                        "description": "The HTML content of the widget to render.",
                    },
                    "widget_id": {
                        "type": "string",
                        "description": "A unique identifier for this widget. Use a descriptive slug.",
                    },
                    "width": {
                        "type": "number",
                        "description": "Widget width in points. Default 320.",
                    },
                    "height": {
                        "type": "number",
                        "description": "Widget height in points. Default 220.",
                    },
                },
                "required": ["html", "widget_id"],
            },
        },
    }
]


def run(messages: list[dict], user_message: str, *, model: str | None = None) -> dict:
    """Call GPT with tool loop. Returns {"text": ..., "widgets": [...]}."""
    model = (model or "").strip() or DEFAULT_MODEL
    msgs = (
        [{"role": "system", "content": SYSTEM_PROMPT}]
        + messages
        + [{"role": "user", "content": user_message}]
    )
    widgets: list[dict] = []

    for _ in range(MAX_TOOL_ROUNDS):
        resp = client.chat.completions.create(model=model, messages=msgs, tools=TOOLS)
        choice = resp.choices[0]

        if choice.finish_reason == "tool_calls" and choice.message.tool_calls:
            msgs.append(choice.message.model_dump())
            for tc in choice.message.tool_calls:
                args = json.loads(tc.function.arguments)
                widget_id = args.get("widget_id", "widget")
                html = args.get("html", "")
                width = _clamp(args.get("width"), 320)
                height = _clamp(args.get("height"), 220)
                widgets.append({
                    "widget_id": widget_id,
                    "html": html,
                    "width": width,
                    "height": height,
                })
                msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": f"Widget '{widget_id}' created ({width}x{height}).",
                })
        else:
            return {"text": choice.message.content or "", "widgets": widgets}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets}


def _clamp(value: object, default: int) -> int:
    try:
        v = int(float(value)) if value is not None else default
    except (TypeError, ValueError):
        v = default
    return max(100, min(1600, v))

"""Backend LLM wrapper with provider fallback: OpenAI -> Anthropic."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

from openai import OpenAI

DEFAULT_MODEL = "gpt-5.2"
DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5-20250929"
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
Keep widgets self-contained (inline CSS/JS, no external frameworks).

## Device Targeting — ALWAYS choose one

Always set `target` for each widget. Never push to both.

- "mac" — reference info that should stay out of the way while the user writes \
or draws. Status panels, lookup results, quick-reference cards, timers.
- "ipad" — content the user should interact with via touch or Apple Pencil. \
Diagrams, spatial layouts, collaborative canvases, dashboards to annotate.

The requesting device is shown in [Device: ...] at the start of each message. \
Use your judgment: if the user is drawing on iPad and asks for reference data, \
push it to the Mac so it doesn't cover their canvas.\
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
                    "target": {
                        "type": "string",
                        "enum": ["ipad", "mac"],
                        "description": "Which device to display this widget on.",
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
                "required": ["html", "widget_id", "target"],
            },
        },
    }
]


def run(messages: list[dict], user_message: str, *, model: str | None = None) -> dict:
    """Run agent with fallback provider.

    Order:
    1. Anthropic (`ANTHROPIC_API_KEY`)
    2. OpenAI (`OPENAI_API_KEY`)
    """
    chosen_model = (model or "").strip() or DEFAULT_MODEL
    anthropic_error: Exception | None = None

    try:
        return _run_anthropic(messages, user_message)
    except Exception as exc:
        anthropic_error = exc

    try:
        return _run_openai(messages, user_message, model=chosen_model)
    except Exception as openai_exc:
        if anthropic_error is not None:
            raise RuntimeError(
                f"Anthropic failed: {anthropic_error}; OpenAI fallback failed: {openai_exc}"
            ) from openai_exc
        raise


def _run_openai(messages: list[dict], user_message: str, *, model: str) -> dict:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    client = OpenAI(api_key=api_key)
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
                target = args.get("target", "mac").strip().lower()
                width = _clamp(args.get("width"), 320)
                height = _clamp(args.get("height"), 220)
                widgets.append({
                    "widget_id": widget_id,
                    "html": html,
                    "target": target,
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


def _run_anthropic(messages: list[dict], user_message: str) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")

    model = os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip() or DEFAULT_ANTHROPIC_MODEL
    widgets: list[dict] = []
    anth_messages = _to_anthropic_messages(messages + [{"role": "user", "content": user_message}])

    for _ in range(MAX_TOOL_ROUNDS):
        body = {
            "model": model,
            "max_tokens": 4096,
            "system": SYSTEM_PROMPT,
            "messages": anth_messages,
            "tools": _anthropic_tools(),
        }
        data = _anthropic_post("/v1/messages", body, api_key)

        content_blocks = data.get("content", [])
        stop_reason = data.get("stop_reason")

        if stop_reason == "tool_use":
            anth_messages.append({"role": "assistant", "content": content_blocks})
            tool_results = []
            for block in content_blocks:
                if block.get("type") != "tool_use":
                    continue
                args = block.get("input") or {}
                widget_id = args.get("widget_id", "widget")
                html = args.get("html", "")
                target = args.get("target", "mac")
                width = _clamp(args.get("width"), 320)
                height = _clamp(args.get("height"), 220)
                widgets.append({
                    "widget_id": widget_id,
                    "html": html,
                    "target": target,
                    "width": width,
                    "height": height,
                })
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.get("id"),
                    "content": f"Widget '{widget_id}' created ({width}x{height}).",
                })
            anth_messages.append({"role": "user", "content": tool_results})
            continue

        text = "".join(
            block.get("text", "")
            for block in content_blocks
            if isinstance(block, dict) and block.get("type") == "text"
        )
        return {"text": text, "widgets": widgets}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets}


def _to_anthropic_messages(messages: list[dict]) -> list[dict]:
    out: list[dict] = []
    for msg in messages:
        role = (msg.get("role") or "").strip()
        content = msg.get("content", "")
        if role not in ("user", "assistant"):
            continue
        if isinstance(content, str):
            out.append({"role": role, "content": content})
        elif isinstance(content, list):
            out.append({"role": role, "content": content})
        else:
            out.append({"role": role, "content": str(content)})
    return out


def _anthropic_tools() -> list[dict]:
    return [
        {
            "name": "push_widget",
            "description": TOOLS[0]["function"]["description"],
            "input_schema": TOOLS[0]["function"]["parameters"],
        }
    ]


def _anthropic_post(path: str, body: dict[str, Any], api_key: str) -> dict[str, Any]:
    req = urllib.request.Request(
        f"https://api.anthropic.com{path}",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"Anthropic HTTP {exc.code}: {detail[:300]}") from exc


def _clamp(value: object, default: int) -> int:
    try:
        v = int(float(value)) if value is not None else default
    except (TypeError, ValueError):
        v = default
    return max(100, min(1600, v))

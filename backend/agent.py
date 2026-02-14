"""Backend LLM wrapper with provider fallback: Anthropic -> OpenAI.

Tooling is modular:
- read_arrows: reads arrow detections from the grounding module
- push_widget: emits widget specs (optionally coordinate-aware)
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

from openai import OpenAI

from grounding import detect_latest_arrows

DEFAULT_MODEL = "gpt-5.2"
DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5-20250929"
MAX_TOOL_ROUNDS = 6

SYSTEM_PROMPT = """\
You are Iris, a visual assistant across iPad and Mac.

Tools:
- read_arrows: inspect latest screenshot arrow detections and endpoints.
- push_widget: create HTML widgets, optionally at coordinates.

Behavior policy:
- Strongly default to NOT placing widgets unless explicitly requested.
- If user asks to place at arrow end/tip, call read_arrows first.
- Prefer tip_document_axis when available.
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_arrows",
            "description": "Read latest detected arrows from grounding system.",
            "parameters": {
                "type": "object",
                "properties": {
                    "device": {
                        "type": "string",
                        "description": "Device id filter, e.g. 'ipad' or 'mac'.",
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Optional session id filter.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "push_widget",
            "description": "Push an HTML widget to a target device.",
            "parameters": {
                "type": "object",
                "properties": {
                    "html": {"type": "string"},
                    "widget_id": {"type": "string"},
                    "width": {"type": "number"},
                    "height": {"type": "number"},
                    "x": {
                        "type": "number",
                        "description": "Optional X position.",
                    },
                    "y": {
                        "type": "number",
                        "description": "Optional Y position.",
                    },
                    "coordinate_space": {
                        "type": "string",
                        "description": "viewport_offset | canvas_absolute | document_axis",
                    },
                    "target_device": {
                        "type": "string",
                        "description": "Optional preferred target device id.",
                    },
                },
                "required": ["html", "widget_id"],
            },
        },
    },
]


def run(
    messages: list[dict],
    user_message: str,
    *,
    model: str | None = None,
    session_id: str | None = None,
    preferred_device: str | None = None,
) -> dict:
    chosen_model = (model or "").strip() or DEFAULT_MODEL
    anthropic_error: Exception | None = None

    try:
        return _run_anthropic(
            messages,
            user_message,
            session_id=session_id,
            preferred_device=preferred_device,
        )
    except Exception as exc:
        anthropic_error = exc

    try:
        return _run_openai(
            messages,
            user_message,
            model=chosen_model,
            session_id=session_id,
            preferred_device=preferred_device,
        )
    except Exception as openai_exc:
        if anthropic_error is not None:
            raise RuntimeError(
                f"Anthropic failed: {anthropic_error}; OpenAI fallback failed: {openai_exc}"
            ) from openai_exc
        raise


def _run_openai(
    messages: list[dict],
    user_message: str,
    *,
    model: str,
    session_id: str | None,
    preferred_device: str | None,
) -> dict:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    client = OpenAI(api_key=api_key)
    msgs = (
        [{"role": "system", "content": SYSTEM_PROMPT}]
        + messages
        + [{"role": "user", "content": user_message}]
    )
    widgets: list[dict[str, Any]] = []

    for _ in range(MAX_TOOL_ROUNDS):
        resp = client.chat.completions.create(model=model, messages=msgs, tools=TOOLS)
        choice = resp.choices[0]

        if choice.finish_reason == "tool_calls" and choice.message.tool_calls:
            msgs.append(choice.message.model_dump())
            for tc in choice.message.tool_calls:
                args = json.loads(tc.function.arguments or "{}")
                tool_content = _handle_tool_call(
                    tc.function.name,
                    args,
                    widgets=widgets,
                    session_id=session_id,
                    preferred_device=preferred_device,
                )
                msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": tool_content,
                })
            continue

        return {"text": choice.message.content or "", "widgets": widgets}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets}


def _run_anthropic(
    messages: list[dict],
    user_message: str,
    *,
    session_id: str | None,
    preferred_device: str | None,
) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")

    model = os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip() or DEFAULT_ANTHROPIC_MODEL
    widgets: list[dict[str, Any]] = []
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
                name = block.get("name")
                args = block.get("input") or {}
                tool_content = _handle_tool_call(
                    str(name or ""),
                    args if isinstance(args, dict) else {},
                    widgets=widgets,
                    session_id=session_id,
                    preferred_device=preferred_device,
                )
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.get("id"),
                    "content": tool_content,
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


def _handle_tool_call(
    name: str,
    args: dict[str, Any],
    *,
    widgets: list[dict[str, Any]],
    session_id: str | None,
    preferred_device: str | None,
) -> str:
    if name == "read_arrows":
        device = str(args.get("device") or preferred_device or "ipad").strip() or "ipad"
        sid = str(args.get("session_id") or session_id or "").strip() or None
        grounded = detect_latest_arrows(device=device, session_id=sid)
        return json.dumps(grounded.to_json(), ensure_ascii=False)

    if name == "push_widget":
        widget_id = str(args.get("widget_id") or "widget")
        html = str(args.get("html") or "")
        width = _clamp(args.get("width"), 320)
        height = _clamp(args.get("height"), 220)
        x = _optional_float(args.get("x"))
        y = _optional_float(args.get("y"))
        coordinate_space = str(args.get("coordinate_space") or "viewport_offset").strip() or "viewport_offset"
        target_device = str(args.get("target_device") or preferred_device or "").strip() or None

        widgets.append({
            "widget_id": widget_id,
            "html": html,
            "width": width,
            "height": height,
            "x": x,
            "y": y,
            "coordinate_space": coordinate_space,
            "target_device": target_device,
        })
        return (
            f"Widget '{widget_id}' created ({width}x{height})"
            + (f" at {coordinate_space} ({x}, {y})" if x is not None and y is not None else "")
        )

    return f"Unsupported tool: {name}"


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
            "name": TOOLS[0]["function"]["name"],
            "description": TOOLS[0]["function"]["description"],
            "input_schema": TOOLS[0]["function"]["parameters"],
        },
        {
            "name": TOOLS[1]["function"]["name"],
            "description": TOOLS[1]["function"]["description"],
            "input_schema": TOOLS[1]["function"]["parameters"],
        },
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


def _optional_float(value: Any) -> float | None:
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None

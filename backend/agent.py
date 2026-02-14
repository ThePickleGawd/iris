"""Backend LLM wrapper with provider fallback: Anthropic -> OpenAI.

Tooling is modular:
- read_arrows: reads arrow detections from the grounding module
- push_widget: emits widget specs (optionally coordinate-aware)
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
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
- read_screenshot: inspect the latest screenshot and summarize visual content.
- read_arrows: inspect latest screenshot arrow detections and endpoints.
- push_widget: create HTML widgets, optionally at coordinates.

Behavior policy:
- Strongly default to NOT placing widgets unless explicitly requested.
- For visual requests, call read_screenshot before deciding.
- If user asks to place at arrow end/tip, call read_arrows first.
- Prefer tip_document_axis when available.
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_screenshot",
            "description": "Read latest screenshot and return a visual description plus metadata.",
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


def generate_widget_from_prompt(
    *,
    context: list[dict[str, Any]],
    user_message: str,
    model: str | None = None,
    preferred_device: str | None = None,
) -> dict[str, Any] | None:
    """Deterministic fallback path: force a single widget spec from prompt."""
    prompt = (
        "Create exactly one UI widget for this request.\n"
        "Return strict JSON only:\n"
        '{"html":"<html...>","width":320,"height":220,"coordinate_space":"viewport_offset","x":0,"y":0}\n'
        "Rules: HTML only in html field, no markdown fences, no prose."
    )
    ctx_tail = context[-6:] if context else []
    compact_context = "\n".join(
        f"{m.get('role','user')}: {str(m.get('content',''))[:500]}"
        for m in ctx_tail
    )
    full_user = f"{prompt}\n\nContext:\n{compact_context}\n\nRequest:\n{user_message}"

    # Prefer Anthropic, fallback OpenAI.
    try:
        text = _generate_text_anthropic(full_user)
    except Exception:
        try:
            text = _generate_text_openai(full_user, model=(model or DEFAULT_MODEL))
        except Exception:
            text = ""

    parsed = _parse_widget_json(text)
    if not parsed:
        # Hard fallback widget to keep behavior deterministic.
        snippet = re.sub(r"\s+", " ", user_message).strip()[:320]
        html = (
            "<div style='font-family:-apple-system,system-ui,sans-serif;padding:14px;"
            "border-radius:14px;background:#111827;color:#f9fafb;border:1px solid #374151;'>"
            "<div style='font-size:12px;opacity:.75;margin-bottom:6px;'>Iris Widget</div>"
            f"<div style='font-size:14px;line-height:1.35;'>{_escape_html(snippet)}</div>"
            "</div>"
        )
        parsed = {"html": html, "width": 360, "height": 220, "x": 0, "y": 0, "coordinate_space": "viewport_offset"}

    return {
        "widget_id": f"forced-{os.urandom(4).hex()}",
        "html": str(parsed.get("html") or ""),
        "width": _clamp(parsed.get("width"), 320),
        "height": _clamp(parsed.get("height"), 220),
        "x": _optional_float(parsed.get("x")) or 0.0,
        "y": _optional_float(parsed.get("y")) or 0.0,
        "coordinate_space": str(parsed.get("coordinate_space") or "viewport_offset"),
        "target_device": str(preferred_device or "ipad").lower(),
        "target": str(preferred_device or "ipad").lower(),
    }


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

    if name == "read_screenshot":
        device = str(args.get("device") or preferred_device or "ipad").strip() or "ipad"
        sid = str(args.get("session_id") or session_id or "").strip() or None
        payload = _read_latest_screenshot(device=device, session_id=sid)
        return json.dumps(payload, ensure_ascii=False)

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
        {
            "name": TOOLS[2]["function"]["name"],
            "description": TOOLS[2]["function"]["description"],
            "input_schema": TOOLS[2]["function"]["parameters"],
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


def _generate_text_anthropic(user_message: str) -> str:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")
    model = os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip() or DEFAULT_ANTHROPIC_MODEL
    data = _anthropic_post(
        "/v1/messages",
        {
            "model": model,
            "max_tokens": 2000,
            "messages": [{"role": "user", "content": user_message}],
        },
        api_key,
    )
    content_blocks = data.get("content", [])
    return "".join(
        block.get("text", "")
        for block in content_blocks
        if isinstance(block, dict) and block.get("type") == "text"
    )


def _generate_text_openai(user_message: str, *, model: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    client = OpenAI(api_key=api_key)
    resp = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": user_message}],
    )
    return resp.choices[0].message.content or ""


def _parse_widget_json(text: str) -> dict[str, Any] | None:
    raw = (text or "").strip()
    if not raw:
        return None
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw
        raw = raw.rsplit("```", 1)[0]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _escape_html(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#39;")
    )


def _read_latest_screenshot(*, device: str | None, session_id: str | None) -> dict[str, Any]:
    rows = _list_screenshot_rows()
    selected: dict[str, Any] | None = None
    for row in rows:
        if device and str(row.get("device_id") or "").strip() != device:
            continue
        if session_id and str(row.get("session_id") or "").strip() != session_id:
            continue
        selected = row
        break

    if not selected:
        return {
            "ok": False,
            "reason": "no screenshot found",
            "device_id": device,
            "session_id": session_id,
        }

    file_path = Path(str(selected.get("file_path") or ""))
    if not file_path.exists():
        return {
            "ok": False,
            "reason": "screenshot file missing",
            "screenshot_id": selected.get("id"),
            "device_id": selected.get("device_id"),
            "session_id": selected.get("session_id"),
        }

    description = _describe_image_for_tool(file_path, str(selected.get("mime_type") or "image/png"))
    return {
        "ok": True,
        "screenshot_id": selected.get("id"),
        "device_id": selected.get("device_id"),
        "session_id": selected.get("session_id"),
        "created_at": selected.get("created_at"),
        "coordinate_snapshot": selected.get("coordinate_snapshot"),
        "description": description,
    }


def _list_screenshot_rows() -> list[dict[str, Any]]:
    meta_dir = Path(__file__).resolve().parent / "data" / "screenshot_meta"
    if not meta_dir.exists():
        return []
    rows: list[dict[str, Any]] = []
    for p in meta_dir.glob("*.json"):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            rows.append(data)
    rows.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
    return rows


def _describe_image_for_tool(file_path: Path, mime_type: str) -> str:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        return "Screenshot available, but visual analysis unavailable (ANTHROPIC_API_KEY not set)."

    try:
        import base64
        b64 = base64.b64encode(file_path.read_bytes()).decode("ascii")
    except OSError:
        return "Screenshot file unreadable."

    prompt = (
        "Describe exactly what is visible in this screenshot. "
        "Focus on text, diagrams, arrows, and spatial layout relevant to assistant actions."
    )
    body = {
        "model": os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip() or DEFAULT_ANTHROPIC_MODEL,
        "max_tokens": 1200,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image", "source": {"type": "base64", "media_type": mime_type, "data": b64}},
                ],
            }
        ],
    }
    try:
        data = _anthropic_post("/v1/messages", body, api_key)
        content_blocks = data.get("content", [])
        text = "".join(
            block.get("text", "")
            for block in content_blocks
            if isinstance(block, dict) and block.get("type") == "text"
        )
        return text.strip() or "Screenshot analyzed, but model returned no description."
    except Exception as exc:
        return f"Screenshot available, analysis failed: {exc}"


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

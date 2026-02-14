"""Backend LLM wrapper with model-routed providers (OpenAI, Anthropic, Gemini)."""
from __future__ import annotations

import base64
import json
import os
import struct
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from openai import OpenAI

DEFAULT_MODEL = "gpt-5.2"
DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5-20250929"
DEFAULT_GEMINI_MODEL = "gemini-2.0-flash"
MAX_TOOL_ROUNDS = 6

SYSTEM_PROMPT = """\
You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can push interactive HTML widgets to devices using the push_widget tool.

## Widget Design Standards

When creating widgets, produce a clean, minimal Apple-style UI — never generic utility HTML.
Widgets exist to help the user make progress on their current task, not to rephrase what they already wrote.

**Required style:**
- Light surfaces by default: white / very light gray backgrounds with subtle separators.
- High legibility: SF-like system typography, restrained weights, generous whitespace.
- Minimal color: neutral palette with one soft accent (blue/teal/indigo), no loud neon.
- Soft geometry: rounded corners (10-16px), thin borders, very subtle shadows.
- Information density: concise and scannable; avoid dense dashboards unless explicitly requested.
- Motion/effects: minimal; no flashy gradients, no busy animations.
- Layout quality: clear hierarchy (title, short context, action/options) and predictable spacing.

**Output constraints:**
- HTML must be self-contained (inline CSS/JS only, no external frameworks).
- Keep widget size practical for iPad canvas (generally 300-520w, 160-320h unless necessary).
- Prefer simple components: cards, small lists, compact tables, checklists, next-step panels.

## Spatial Placement Rules

- For precise placement requests (arrows, callouts, specific regions), call `read_screenshot` first.
- Then call `push_widget` with explicit `x`, `y`, `coordinate_space`, and `anchor`.
- Prefer `coordinate_space = document_axis` when the request references stable canvas geometry.
- Use `coordinate_space = viewport_offset` for "near what the user is currently viewing".
- If coordinate snapshot includes `mostRecentStrokeCenterAxis`, prefer placing assistance widgets near that point when no explicit response area is provided.
- If screenshot analysis yields pixel anchors and coordinate snapshot provides viewport bounds:
  map using:
  - canvas_x = viewport_min_x + (pixel_x / image_width) * viewport_width
  - canvas_y = viewport_min_y + (pixel_y / image_height) * viewport_height
- Never omit coordinates for placement-sensitive tasks.

## Latency + Accuracy Contract

- Minimize round trips: at most one `read_screenshot` call before first `push_widget`.
- Do not ask clarifying questions unless critical ambiguity blocks safe placement.
- If confidence is sufficient, emit widgets immediately in the same turn.
- Prefer 1-2 high-value widgets over many low-confidence widgets.

## Deterministic Placement

- Always output `x`, `y`, `coordinate_space`, and `anchor` for every `push_widget`.
- Default to `coordinate_space=document_axis` and `anchor=top_left` unless request is viewport-relative.
- If exact anchor is uncertain, place near inferred target with conservative size.

## Fast Widget Generation

- Keep HTML/CSS minimal (no heavy effects, no unnecessary animations, no external assets).
- Keep payload concise and scannable; avoid long prose blocks.
- Prefer compact card-style layouts with short labels.

## Suggestion vs Direct Action

- Direct user voice/requested widget creation: place actual widget, not suggestion chip.
- Proactive workflow: emit suggestion widgets only, with `widget_id` starting `proactive-suggestion-`.

## Output Discipline

- Never emit duplicate widgets in one response.
- If screenshot signal is weak, return no widget instead of low-confidence placement.
- Do not merely restate the user's problem in the widget body.
- Prefer actionable assistance: solve steps, worked examples, error checks, next action options, or decision support.
- For math/problem-solving contexts, include concrete intermediate reasoning structure (steps/formula/check), not only a paraphrase.
- The widget must directly contain the answer the user needs.
- Do not require additional interaction to reveal the core answer.
\
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
                    "x": {
                        "type": "number",
                        "description": "Widget anchor X coordinate in the selected coordinate_space.",
                    },
                    "y": {
                        "type": "number",
                        "description": "Widget anchor Y coordinate in the selected coordinate_space.",
                    },
                    "coordinate_space": {
                        "type": "string",
                        "description": "Coordinate frame for x/y: viewport_offset | canvas_absolute | document_axis",
                    },
                    "anchor": {
                        "type": "string",
                        "description": "Anchor point for x/y: top_left | center",
                    },
                },
                "required": ["html", "widget_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_screenshot",
            "description": (
                "Read and analyze the latest screenshot for spatial cues (arrows, highlighted regions, "
                "pixel-relative anchors) and return placement guidance."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "string",
                        "description": "Optional device filter (e.g. 'ipad', 'mac').",
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Optional session filter to scope screenshot selection.",
                    },
                    "question": {
                        "type": "string",
                        "description": "Specific spatial question to answer about the screenshot.",
                    },
                },
                "required": [],
            },
        },
    },
]


def run(messages: list[dict], user_message: str, *, model: str | None = None) -> dict:
    """Run agent routed by model/provider, with compatibility fallback."""
    chosen_model = (model or "").strip() or DEFAULT_MODEL
    provider = _provider_for_model(chosen_model)

    if provider == "gemini":
        resolved = _resolve_gemini_model(chosen_model)
        return _run_gemini(messages, user_message, model=resolved)

    if provider == "anthropic":
        return _run_anthropic(messages, user_message, model=_resolve_anthropic_model(chosen_model))

    if provider == "openai":
        try:
            return _run_openai(messages, user_message, model=chosen_model)
        except Exception as openai_exc:
            try:
                return _run_anthropic(messages, user_message, model=None)
            except Exception as anthropic_exc:
                raise RuntimeError(
                    f"OpenAI failed: {openai_exc}; Anthropic fallback failed: {anthropic_exc}"
                ) from anthropic_exc

    # Unknown alias fallback for compatibility.
    anthropic_error: Exception | None = None
    try:
        return _run_anthropic(messages, user_message, model=None)
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
                if tc.function.name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": (
                            f"Widget '{widget['widget_id']}' created "
                            f"({widget['width']}x{widget['height']}) at "
                            f"{widget['coordinate_space']} "
                            f"({widget['x']}, {widget['y']}) anchor={widget['anchor']}."
                        ),
                    })
                    continue

                if tc.function.name == "read_screenshot":
                    analysis = _handle_read_screenshot(args)
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": analysis,
                    })
                    continue

                msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": f"Unsupported tool '{tc.function.name}'.",
                })
        else:
            return {"text": choice.message.content or "", "widgets": widgets}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets}


def _run_anthropic(messages: list[dict], user_message: str, *, model: str | None = None) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")

    model = (
        (model or "").strip()
        or os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip()
        or DEFAULT_ANTHROPIC_MODEL
    )
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
                tool_name = block.get("name")
                if tool_name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": (
                            f"Widget '{widget['widget_id']}' created "
                            f"({widget['width']}x{widget['height']}) at "
                            f"{widget['coordinate_space']} "
                            f"({widget['x']}, {widget['y']}) anchor={widget['anchor']}."
                        ),
                    })
                    continue

                if tool_name == "read_screenshot":
                    analysis = _handle_read_screenshot(args)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": analysis,
                    })
                    continue

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.get("id"),
                    "content": f"Unsupported tool '{tool_name}'.",
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


def _run_gemini(messages: list[dict], user_message: str, *, model: str) -> dict:
    api_key = (
        os.environ.get("GEMINI_API_KEY", "").strip()
        or os.environ.get("GOOGLE_API_KEY", "").strip()
    )
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY or GOOGLE_API_KEY is not set")

    contents = _to_gemini_contents(messages + [{"role": "user", "content": user_message}])
    widgets: list[dict[str, Any]] = []
    no_candidate_count = 0

    for _ in range(MAX_TOOL_ROUNDS):
        body = {
            "system_instruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": contents,
            "tools": [{"function_declarations": _gemini_function_declarations()}],
        }
        data = _gemini_post(model, body, api_key)
        candidates = data.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            no_candidate_count += 1
            if no_candidate_count < 2:
                continue
            prompt_feedback = data.get("promptFeedback") if isinstance(data.get("promptFeedback"), dict) else {}
            block_reason = str(prompt_feedback.get("blockReason") or "").strip()
            block_message = str(prompt_feedback.get("blockReasonMessage") or "").strip()
            detail = "Gemini returned no candidates."
            if block_reason:
                detail = f"{detail} blockReason={block_reason}"
            if block_message:
                detail = f"{detail} {block_message}"
            return {"text": detail, "widgets": widgets}
        no_candidate_count = 0

        candidate = candidates[0] if isinstance(candidates[0], dict) else {}
        content = candidate.get("content") if isinstance(candidate.get("content"), dict) else {}
        parts = content.get("parts") if isinstance(content.get("parts"), list) else []

        function_calls: list[dict[str, Any]] = []
        for part in parts:
            if not isinstance(part, dict):
                continue
            call = part.get("functionCall")
            if isinstance(call, dict):
                function_calls.append(call)

        if function_calls:
            contents.append({"role": "model", "parts": [{"functionCall": fc} for fc in function_calls]})
            tool_response_parts: list[dict[str, Any]] = []
            for call in function_calls:
                name = str(call.get("name") or "").strip()
                args = call.get("args")
                if not isinstance(args, dict):
                    args = {}

                if name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": {
                                "ok": True,
                                "widget_id": widget["widget_id"],
                                "detail": (
                                    f"Widget placed at {widget['coordinate_space']} "
                                    f"({widget['x']}, {widget['y']})"
                                ),
                            },
                        }
                    })
                    continue

                if name == "read_screenshot":
                    analysis = _handle_read_screenshot(args)
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": {"ok": True, "analysis": analysis},
                        }
                    })
                    continue

                tool_response_parts.append({
                    "functionResponse": {
                        "name": name or "unknown",
                        "response": {"ok": False, "error": f"Unsupported tool '{name}'"},
                    }
                })

            contents.append({"role": "user", "parts": tool_response_parts})
            continue

        text = "".join(
            part.get("text", "")
            for part in parts
            if isinstance(part, dict) and isinstance(part.get("text"), str)
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
    out: list[dict] = []
    for tool in TOOLS:
        fn = tool["function"]
        out.append(
            {
                "name": fn["name"],
                "description": fn["description"],
                "input_schema": fn["parameters"],
            }
        )
    return out


def _gemini_function_declarations() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for tool in TOOLS:
        fn = tool["function"]
        out.append({
            "name": fn["name"],
            "description": fn["description"],
            "parameters": fn["parameters"],
        })
    return out


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


def _gemini_post(model: str, body: dict[str, Any], api_key: str) -> dict[str, Any]:
    encoded_model = urllib.parse.quote(model, safe="")
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{encoded_model}:generateContent?key={api_key}",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={"content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"Gemini HTTP {exc.code}: {detail[:300]}") from exc


def _clamp(value: object, default: int) -> int:
    try:
        v = int(float(value)) if value is not None else default
    except (TypeError, ValueError):
        v = default
    return max(100, min(1600, v))


def _coerce_float(value: object, default: float = 0.0) -> float:
    try:
        return float(value) if value is not None else default
    except (TypeError, ValueError):
        return default


def _normalize_coordinate_space(value: object) -> str:
    raw = str(value or "viewport_offset").strip().lower()
    if raw in {"viewport_offset", "canvas_absolute", "document_axis"}:
        return raw
    return "viewport_offset"


def _normalize_anchor(value: object) -> str:
    raw = str(value or "top_left").strip().lower()
    if raw in {"top_left", "center"}:
        return raw
    return "top_left"


def _normalize_widget_args(args: dict[str, Any]) -> dict[str, Any]:
    return {
        "widget_id": str(args.get("widget_id") or "widget"),
        "html": str(args.get("html") or ""),
        "width": _clamp(args.get("width"), 320),
        "height": _clamp(args.get("height"), 220),
        "x": _coerce_float(args.get("x"), 0.0),
        "y": _coerce_float(args.get("y"), 0.0),
        "coordinate_space": _normalize_coordinate_space(args.get("coordinate_space")),
        "anchor": _normalize_anchor(args.get("anchor")),
    }


def _handle_read_screenshot(args: dict[str, Any]) -> str:
    device_id = str(args.get("device_id") or "").strip() or None
    session_id = str(args.get("session_id") or "").strip() or None
    question = str(args.get("question") or "").strip() or (
        "Identify key visual anchors, arrows, and useful widget placement locations."
    )

    backend_dir = Path(__file__).resolve().parent
    meta_dir = backend_dir / "data" / "screenshot_meta"
    rows: list[dict[str, Any]] = []
    for meta_path in meta_dir.glob("*.json"):
        try:
            row = json.loads(meta_path.read_text(encoding="utf-8"))
            if not isinstance(row, dict):
                continue
            rows.append(row)
        except (OSError, json.JSONDecodeError):
            continue

    if device_id:
        rows = [row for row in rows if str(row.get("device_id") or "") == device_id]
    if session_id:
        rows = [row for row in rows if str(row.get("session_id") or "") == session_id]

    rows.sort(key=lambda row: str(row.get("created_at") or ""), reverse=True)
    if not rows:
        return "No screenshot available for the requested filters."

    row = rows[0]
    file_path = Path(str(row.get("file_path") or ""))
    if not file_path.exists():
        return f"Latest screenshot metadata found (id={row.get('id')}), but file is missing."

    meta_summary = {
        "screenshot_id": row.get("id"),
        "device_id": row.get("device_id"),
        "session_id": row.get("session_id"),
        "created_at": row.get("created_at"),
        "notes": row.get("notes"),
    }
    dimensions = _image_dimensions(file_path, str(row.get("mime_type") or ""))
    if dimensions is not None:
        meta_summary["image_width"] = dimensions[0]
        meta_summary["image_height"] = dimensions[1]

    vision_text = _analyze_screenshot_with_openai(file_path, row, question)
    return json.dumps(
        {
            "metadata": meta_summary,
            "analysis": vision_text,
            "instruction": (
                "Use this analysis with coordinate metadata from the request to place widgets precisely."
            ),
        },
        ensure_ascii=False,
    )


def describe_screenshot_with_gemini(
    file_path: Path,
    mime_type: str,
    *,
    coordinate_snapshot: dict[str, Any] | None = None,
    previous_description: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return a stable JSON description for proactive screenshot monitoring."""
    api_key = (
        os.environ.get("GEMINI_API_KEY", "").strip()
        or os.environ.get("GOOGLE_API_KEY", "").strip()
    )
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY or GOOGLE_API_KEY is not set")

    model = os.environ.get("PROACTIVE_GEMINI_MODEL", DEFAULT_GEMINI_MODEL).strip() or DEFAULT_GEMINI_MODEL
    data_b64 = base64.b64encode(file_path.read_bytes()).decode("ascii")
    snapshot_json = json.dumps(coordinate_snapshot or {}, ensure_ascii=False)
    previous_json = json.dumps(previous_description or {}, ensure_ascii=False)

    prompt = (
        "Analyze this iPad canvas screenshot for proactive widget opportunities. "
        "Return JSON only. Keep keys and structure consistent across images.\n\n"
        "Required schema:\n"
        "{"
        "\"schema_version\":\"1.0\","
        "\"scene_summary\":\"string\","
        "\"problem_to_solve\":\"string\","
        "\"task_objective\":\"string\","
        "\"success_criteria\":[\"string\"],"
        "\"canvas_state\":{\"is_blank\":bool,\"density\":\"low|medium|high\",\"primary_mode\":\"drawing|text|mixed|unknown\"},"
        "\"regions\":[{\"id\":\"r1\",\"label\":\"string\",\"kind\":\"text|diagram|list|table|equation|ui|unknown\","
        "\"bbox_norm\":{\"x\":0..1,\"y\":0..1,\"w\":0..1,\"h\":0..1},\"salience\":0..1}],"
        "\"suggestion_candidates\":[{\"id\":\"s1\",\"title\":\"string\",\"summary\":\"string\","
        "\"anchor_norm\":{\"x\":0..1,\"y\":0..1},\"confidence\":0..1}],"
        "\"change_assessment\":{\"novelty_vs_previous\":0..1,\"notable_changes\":[\"string\"]}"
        "}\n\n"
        "Rules:\n"
        "- Use normalized coordinates in [0,1].\n"
        "- Include at most 6 regions and 6 suggestion_candidates.\n"
        "- If no candidate exists, return an empty suggestion_candidates array.\n"
        "- problem_to_solve and task_objective must be concrete, action-guiding strings.\n"
        "- success_criteria should be 1-4 concise bullets.\n"
        "- Do not add extra top-level keys.\n\n"
        f"Coordinate snapshot: {snapshot_json}\n"
        f"Previous description: {previous_json}\n"
    )

    body = {
        "system_instruction": {
            "parts": [{
                "text": (
                    "You are a strict vision parser. Return valid JSON only, matching the provided schema."
                )
            }]
        },
        "contents": [{
            "role": "user",
            "parts": [
                {"text": prompt},
                {"inline_data": {"mime_type": mime_type or "image/png", "data": data_b64}},
            ],
        }],
        "generationConfig": {
            "temperature": 0.1,
            "responseMimeType": "application/json",
        },
    }

    raw = _gemini_post(model, body, api_key)
    text = _extract_gemini_text(raw)
    parsed = _parse_json_object(text)
    return _normalize_proactive_description(parsed)


def _analyze_screenshot_with_openai(file_path: Path, row: dict[str, Any], question: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        return "OPENAI_API_KEY not set; only screenshot metadata available."

    mime = str(row.get("mime_type") or "image/png")
    image_b64 = base64.b64encode(file_path.read_bytes()).decode("ascii")
    vision_model = os.environ.get("OPENAI_VISION_MODEL", "gpt-4.1-mini").strip() or "gpt-4.1-mini"

    prompt = (
        "Analyze the screenshot for spatial placement. "
        "If arrows, callouts, or highlighted targets exist, report approximate pixel coordinates. "
        "Return concise bullet points with candidate anchors and rationale.\n"
        f"Question: {question}"
    )

    client = OpenAI(api_key=api_key)
    resp = client.chat.completions.create(
        model=vision_model,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{image_b64}"}},
                ],
            }
        ],
        max_tokens=500,
    )
    return resp.choices[0].message.content or ""


def _extract_gemini_text(payload: dict[str, Any]) -> str:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list):
        return ""
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        content = candidate.get("content")
        if not isinstance(content, dict):
            continue
        parts = content.get("parts")
        if not isinstance(parts, list):
            continue
        for part in parts:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                return part["text"]
    return ""


def _parse_json_object(text: str) -> dict[str, Any]:
    txt = (text or "").strip()
    if not txt:
        raise RuntimeError("Gemini returned empty JSON text")
    try:
        obj = json.loads(txt)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    start = txt.find("{")
    end = txt.rfind("}")
    if start >= 0 and end > start:
        try:
            obj = json.loads(txt[start:end + 1])
            if isinstance(obj, dict):
                return obj
        except json.JSONDecodeError:
            pass
    raise RuntimeError("Gemini returned invalid JSON object")


def _normalize_proactive_description(raw: dict[str, Any]) -> dict[str, Any]:
    def _f01(value: Any, default: float = 0.0) -> float:
        try:
            return max(0.0, min(1.0, float(value)))
        except (TypeError, ValueError):
            return default

    canvas_state = raw.get("canvas_state") if isinstance(raw.get("canvas_state"), dict) else {}
    density = str(canvas_state.get("density") or "low").lower()
    if density not in {"low", "medium", "high"}:
        density = "low"
    primary_mode = str(canvas_state.get("primary_mode") or "unknown").lower()
    if primary_mode not in {"drawing", "text", "mixed", "unknown"}:
        primary_mode = "unknown"

    regions: list[dict[str, Any]] = []
    for i, item in enumerate(raw.get("regions") or []):
        if not isinstance(item, dict):
            continue
        bbox = item.get("bbox_norm") if isinstance(item.get("bbox_norm"), dict) else {}
        kind = str(item.get("kind") or "unknown").lower()
        if kind not in {"text", "diagram", "list", "table", "equation", "ui", "unknown"}:
            kind = "unknown"
        regions.append({
            "id": str(item.get("id") or f"r{i + 1}"),
            "label": str(item.get("label") or ""),
            "kind": kind,
            "bbox_norm": {
                "x": _f01(bbox.get("x"), 0.0),
                "y": _f01(bbox.get("y"), 0.0),
                "w": _f01(bbox.get("w"), 0.0),
                "h": _f01(bbox.get("h"), 0.0),
            },
            "salience": _f01(item.get("salience"), 0.0),
        })
        if len(regions) >= 6:
            break

    candidates: list[dict[str, Any]] = []
    for i, item in enumerate(raw.get("suggestion_candidates") or []):
        if not isinstance(item, dict):
            continue
        anchor = item.get("anchor_norm") if isinstance(item.get("anchor_norm"), dict) else {}
        candidates.append({
            "id": str(item.get("id") or f"s{i + 1}"),
            "title": str(item.get("title") or "Suggestion"),
            "summary": str(item.get("summary") or ""),
            "anchor_norm": {
                "x": _f01(anchor.get("x"), 0.5),
                "y": _f01(anchor.get("y"), 0.5),
            },
            "confidence": _f01(item.get("confidence"), 0.0),
        })
        if len(candidates) >= 6:
            break

    change = raw.get("change_assessment") if isinstance(raw.get("change_assessment"), dict) else {}
    notable_changes_raw = change.get("notable_changes")
    notable_changes: list[str] = []
    if isinstance(notable_changes_raw, list):
        notable_changes = [str(v) for v in notable_changes_raw if str(v).strip()][:8]

    success_criteria_raw = raw.get("success_criteria")
    success_criteria: list[str] = []
    if isinstance(success_criteria_raw, list):
        success_criteria = [str(v) for v in success_criteria_raw if str(v).strip()][:4]

    return {
        "schema_version": "1.0",
        "scene_summary": str(raw.get("scene_summary") or ""),
        "problem_to_solve": str(raw.get("problem_to_solve") or ""),
        "task_objective": str(raw.get("task_objective") or ""),
        "success_criteria": success_criteria,
        "canvas_state": {
            "is_blank": bool(canvas_state.get("is_blank")),
            "density": density,
            "primary_mode": primary_mode,
        },
        "regions": regions,
        "suggestion_candidates": candidates,
        "change_assessment": {
            "novelty_vs_previous": _f01(change.get("novelty_vs_previous"), 0.0),
            "notable_changes": notable_changes,
        },
    }


def _image_dimensions(file_path: Path, mime_type: str) -> tuple[int, int] | None:
    try:
        data = file_path.read_bytes()
    except OSError:
        return None

    if mime_type == "image/png" or data.startswith(b"\x89PNG\r\n\x1a\n"):
        if len(data) >= 24:
            width = struct.unpack(">I", data[16:20])[0]
            height = struct.unpack(">I", data[20:24])[0]
            if width > 0 and height > 0:
                return width, height
        return None

    # Minimal JPEG parser (SOF segment)
    if mime_type in {"image/jpeg", "image/jpg"} or data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            i += 2
            if marker in {0xD8, 0xD9}:
                continue
            if i + 2 > len(data):
                break
            seg_len = struct.unpack(">H", data[i:i + 2])[0]
            if seg_len < 2 or i + seg_len > len(data):
                break
            if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
                if i + 7 <= len(data):
                    height = struct.unpack(">H", data[i + 3:i + 5])[0]
                    width = struct.unpack(">H", data[i + 5:i + 7])[0]
                    if width > 0 and height > 0:
                        return width, height
                break
            i += seg_len
    return None


def _to_gemini_contents(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for msg in messages:
        role = str(msg.get("role") or "").strip()
        if role not in {"user", "assistant"}:
            continue
        raw_content = msg.get("content", "")
        if isinstance(raw_content, str):
            text = raw_content
        elif isinstance(raw_content, list):
            text = "\n".join(str(item) for item in raw_content)
        else:
            text = str(raw_content)
        out.append({
            "role": "model" if role == "assistant" else "user",
            "parts": [{"text": text}],
        })
    return out


def _provider_for_model(model: str) -> str:
    lowered = model.lower()
    if lowered == "claude" or lowered.startswith("claude"):
        return "anthropic"
    if lowered in {"gemini", "gemini-flash"} or lowered.startswith("gemini"):
        return "gemini"
    if lowered.startswith(("gpt-", "o1", "o3", "o4", "codex")):
        return "openai"
    return "unknown"


def _resolve_anthropic_model(model: str) -> str | None:
    if model.lower() == "claude":
        return None
    return model


def _resolve_gemini_model(model: str) -> str:
    lowered = model.lower()
    if lowered in {"gemini", "gemini-flash"}:
        return DEFAULT_GEMINI_MODEL
    return model

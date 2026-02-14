"""Backend LLM wrapper with model-routed providers (OpenAI, Anthropic, Gemini)."""
from __future__ import annotations

import base64
import html as html_module
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_MODEL = "gpt-5.2"
DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-5-20250929"
DEFAULT_GEMINI_MODEL = "gemini-2.0-flash"
MAX_TOOL_ROUNDS = 6

_WIDGETS_DIR = Path(__file__).resolve().parent.parent / "widgets"


def _load_widget_catalog() -> str:
    """Build a concise catalog of available library widgets from manifest + meta files."""
    manifest_path = _WIDGETS_DIR / "lib" / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "No widget library found."

    slugs = manifest.get("widgets", [])
    if not slugs:
        return "Widget library is empty."

    lines = ["Available library widgets (use `read_widget` to get the full HTML):"]
    for slug in slugs:
        meta_path = _WIDGETS_DIR / "lib" / slug / "meta.json"
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        name = meta.get("name", slug)
        desc = meta.get("description", "")
        w = meta.get("defaultWidth", "?")
        h = meta.get("defaultHeight", "?")
        tags = ", ".join(meta.get("tags", []))
        lines.append(f"- **{name}** (`{slug}`): {desc} — {w}×{h} [{tags}]")

    return "\n".join(lines)


def _build_system_prompt() -> str:
    """Build the full system prompt with the dynamic widget catalog injected."""
    catalog = _load_widget_catalog()
    return _SYSTEM_PROMPT_TEMPLATE.replace("{widget_catalog}", catalog)


_SYSTEM_PROMPT_TEMPLATE = """\
You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can push widgets to devices using the push_widget tool.

## Widget Types

Each widget has a `type` that determines how it's rendered. Choose the right type:

### `document` — Rich text, math, code
Best for: explanations, derivations, reference material, anything with LaTeX math or code blocks.
- Set `type: "document"` and `source` to **Markdown** text.
- Use `$...$` for inline math, `$$...$$` for display math (LaTeX).
- Use fenced code blocks (```lang) for syntax-highlighted code.
- Do NOT set `html` — the backend renders it automatically.

### `diagram` — Flowcharts, architecture, sequences
Best for: flowcharts, system architecture, sequence diagrams, state machines, ER diagrams.
- Set `type: "diagram"` and `source` to **D2** diagram code.
- D2 syntax reference: nodes with `label`, edges with `->`, containers with `{ }`.
- Do NOT set `html` — the backend renders the D2 to SVG automatically.
- Example D2:
  ```
  user -> auth: Login
  auth -> db: Query
  db -> auth: Result
  auth -> user: Token
  ```

### `animation` — Mathematical animations (Manim)
Best for: step-by-step derivations, geometric transformations, graph animations, \
anything where **motion aids understanding**.
- Set `type: "animation"` and `source` to a **complete Manim scene** (Python code).
- The source MUST define exactly one class that extends `Scene` with a `construct` method.
- Use ManimCE (Community Edition) API. Key classes: `MathTex`, `Tex`, `Text`, \
`Create`, `Write`, `FadeIn`, `Transform`, `Axes`, `NumberPlane`, `Arrow`, `Circle`, etc.
- Do NOT set `html` — the backend renders the animation automatically.
- Renders at 480p/30fps for speed. Keep animations concise (under 15 seconds).
- **Only use when motion genuinely helps.** If a static equation or diagram suffices, \
prefer `document` or `diagram` — they render instantly.
- Example:
  ```python
  from manim import *
  class Example(Scene):
      def construct(self):
          eq = MathTex("e^{i\\pi} + 1 = 0")
          self.play(Write(eq))
          self.wait()
  ```

### `html` — Interactive tools (default)
Best for: timers, calculators, checklists, games, anything needing JS interactivity.
- Set `type: "html"` (or omit — it's the default) and `html` to raw HTML.
- HTML must be self-contained (inline CSS/JS only, no external frameworks).

**Style reference — match real Apple iOS/macOS widgets:**
- Corner radius: 20px (the Apple squircle shape).
- Background: #1c1c1e (dark). No borders or outlines — separation via spacing only.
- Padding: generous, 16–20px all sides. Widgets should feel spacious, never cramped.
- Typography (use -apple-system, SF Pro):
  - Category label: 11–12px, uppercase, bold, accent-colored or muted gray.
  - Hero value: 34–48px, bold. This is the ONE focal element (e.g. "82°", "100%", "14").
  - Body text: 13–14px, regular weight, muted gray (#8e8e93).
- Color: ONE accent per widget, chosen from Apple system palette:
  red #ff3b30, orange #ff9500, green #34c759, blue #007aff, purple #af52de.
  White (#ffffff) for primary text, muted gray (#8e8e93) for secondary.
- Layout: strong hierarchy — small label → big value → small supporting detail.
- Density: show 3–5 pieces of information max. If you need more, it's not a widget.
- No gradients, no shadows, no hover effects. Apple widgets are flat and clean.
- Icons: emoji or small inline text glyphs. Keep them 16–20px.
- Keep widget size practical (generally 280–420w, 160–300h unless content demands more).
- Disable zoom: always include `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">` \
and `touch-action: manipulation` on html/body. Use HTML entities (`&sup2;`, `&#x221A;`) instead of raw Unicode for special characters.

**Widget Library**: Before writing complex HTML from scratch, use `read_widget` to load a \
library widget's HTML and adapt it. This produces much higher quality than writing from scratch.
{widget_catalog}
Workflow: call `read_widget(name="...")` → get HTML + metadata → adapt the HTML → pass to `push_widget`.

## Device Targeting — Pick ONE Device

Every widget goes to exactly one device. Think about what the user is doing and where the widget is most useful.

**`ipad`** — The user's drawing/writing canvas. Choose this when:
- The user is working on the iPad (drawing, writing, solving problems on the canvas).
- The widget is a reference, hint, or aid for what's on the canvas (e.g. formula sheet, step-by-step solution next to their work).
- Spatial placement near their work matters.

**`mac`** — A standalone desktop overlay window. Choose this when:
- The user is at their computer and asked for something conversationally (e.g. "make me a timer", "show a diagram of X").
- The widget is a self-contained tool (timer, calculator, checklist) not tied to canvas content.
- The user explicitly mentions their Mac/desktop, or there's no indication they're using the iPad.

**Decision heuristic**: If the request references something on the canvas or the user is clearly working on the iPad, target `ipad`. Otherwise, default to `mac`. Never send the same widget to both devices.

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
                    "type": {
                        "type": "string",
                        "enum": ["html", "document", "diagram", "animation"],
                        "description": "Widget type: 'document' for markdown/LaTeX, 'diagram' for D2, 'animation' for Manim, 'html' for raw interactive HTML. Default 'html'.",
                    },
                    "source": {
                        "type": "string",
                        "description": "Source content for document (Markdown with LaTeX), diagram (D2 code), or animation (Manim Python scene) types.",
                    },
                    "html": {
                        "type": "string",
                        "description": "Raw HTML content for 'html' type widgets.",
                    },
                    "target": {
                        "type": "string",
                        "enum": ["mac", "ipad"],
                        "description": "Which device to show the widget on. Pick ONE: 'mac' (desktop overlay window) or 'ipad' (canvas widget). Reason about the user's intent to choose.",
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
                "required": ["widget_id", "target"],
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
    {
        "type": "function",
        "function": {
            "name": "read_widget",
            "description": (
                "Load a widget from the library by name. Returns the full HTML source "
                "and metadata (name, description, default dimensions, accent color). "
                "Adapt the HTML as needed and pass it to push_widget."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Widget slug (e.g. 'calculator', 'graph', 'timer').",
                    },
                },
                "required": ["name"],
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
    try:
        from openai import OpenAI
    except Exception as exc:
        raise RuntimeError("openai package is not installed") from exc

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    client = OpenAI(api_key=api_key)
    msgs = (
        [{"role": "system", "content": _build_system_prompt()}]
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

                if tc.function.name == "read_widget":
                    result = _handle_read_widget(args)
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
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
            "system": _build_system_prompt(),
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

                if tool_name == "read_widget":
                    result = _handle_read_widget(args)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": result,
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
            "system_instruction": {"parts": [{"text": _build_system_prompt()}]},
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

                if name == "read_widget":
                    result = _handle_read_widget(args)
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": {"ok": True, "widget": result},
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
    if raw in {"viewport_offset", "viewport_center_offset", "viewport_center"}:
        return "viewport_center_offset"
    if raw in {"viewport_local", "viewport_top_left", "viewport_topleft"}:
        return "viewport_local"
    if raw in {"canvas_absolute", "document_axis"}:
        return raw
    return "viewport_center_offset"


def _normalize_anchor(value: object) -> str:
    raw = str(value or "top_left").strip().lower()
    if raw in {"top_left", "center"}:
        return raw
    return "top_left"


def _render_document_html(source: str) -> str:
    """Render Markdown + LaTeX source into a self-contained HTML document."""
    escaped = html_module.escape(source)
    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css">
<style>
  :root {{ color-scheme: dark; }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: "New York", "Iowan Old Style", Georgia, serif;
    font-size: 15px; line-height: 1.7; color: #e4e4e7;
    background: #18181b; padding: 24px 28px;
    -webkit-font-smoothing: antialiased;
  }}
  h1, h2, h3, h4, h5, h6 {{
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
    color: #fafafa; margin: 1.4em 0 0.5em; line-height: 1.3;
  }}
  h1 {{ font-size: 1.6em; font-weight: 700; }}
  h2 {{ font-size: 1.3em; font-weight: 600; }}
  h3 {{ font-size: 1.1em; font-weight: 600; }}
  p {{ margin: 0.6em 0; }}
  a {{ color: #60a5fa; text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  code {{
    font-family: "SF Mono", Menlo, monospace; font-size: 0.88em;
    background: #27272a; padding: 2px 6px; border-radius: 4px;
  }}
  pre {{ margin: 1em 0; border-radius: 8px; overflow-x: auto; }}
  pre code {{
    display: block; padding: 14px 18px;
    background: #1e1e22; line-height: 1.5;
  }}
  blockquote {{
    border-left: 3px solid #3f3f46; padding-left: 16px;
    color: #a1a1aa; margin: 1em 0;
  }}
  ul, ol {{ margin: 0.6em 0; padding-left: 1.5em; }}
  li {{ margin: 0.25em 0; }}
  table {{ border-collapse: collapse; margin: 1em 0; width: 100%; }}
  th, td {{
    border: 1px solid #3f3f46; padding: 8px 12px; text-align: left;
  }}
  th {{ background: #27272a; font-weight: 600; }}
  hr {{ border: none; border-top: 1px solid #3f3f46; margin: 1.5em 0; }}
  .katex-display {{ margin: 1em 0; overflow-x: auto; }}
</style>
</head>
<body>
<script type="text/template" id="source">{escaped}</script>
<div id="content"></div>
<script src="https://cdn.jsdelivr.net/npm/marked@14.0.0/marked.min.js"></script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
<script>
(function() {{
  marked.setOptions({{
    highlight: function(code, lang) {{
      if (lang && hljs.getLanguage(lang)) {{
        return hljs.highlight(code, {{ language: lang }}).value;
      }}
      return hljs.highlightAuto(code).value;
    }}
  }});
  var src = document.getElementById("source").textContent;
  var el = document.getElementById("content");
  el.innerHTML = marked.parse(src);
  renderMathInElement(el, {{
    delimiters: [
      {{ left: "$$", right: "$$", display: true }},
      {{ left: "$", right: "$", display: false }}
    ],
    throwOnError: false
  }});
}})();
</script>
</body>
</html>"""


def _render_diagram_html(source: str) -> dict[str, Any]:
    """Render D2 diagram source to SVG via the d2 CLI, wrapped in dark HTML.

    Returns {"html": str, "width": int, "height": int}.
    """
    d2_bin = shutil.which("d2")
    if not d2_bin:
        return {"html": _diagram_error_html("d2 binary not found in PATH. Install from https://d2lang.com"),
                "width": 400, "height": 180}

    try:
        result = subprocess.run(
            [d2_bin, "-", "-", "--theme=200", "--pad=20"],
            input=source.encode("utf-8"),
            capture_output=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"html": _diagram_error_html("d2 rendering timed out (30s limit)"),
                "width": 400, "height": 180}
    except OSError as exc:
        return {"html": _diagram_error_html(f"Failed to run d2: {exc}"),
                "width": 400, "height": 180}

    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        return {"html": _diagram_error_html(f"d2 error (exit {result.returncode}):\n{stderr}"),
                "width": 400, "height": 180}

    svg = result.stdout.decode("utf-8")

    # Extract natural dimensions from the SVG viewBox
    svg_w, svg_h = 320, 220
    vb = re.search(r'viewBox="[\d.\-]+ [\d.\-]+ ([\d.]+) ([\d.]+)"', svg)
    if vb:
        try:
            svg_w = int(float(vb.group(1)))
            svg_h = int(float(vb.group(2)))
        except (ValueError, IndexError):
            pass

    # Widget = SVG + body padding (16px each side)
    widget_w = svg_w + 32
    widget_h = svg_h + 32

    html = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
  :root {{ color-scheme: dark; }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    background: #18181b; display: flex;
    align-items: center; justify-content: center;
    min-height: 100vh; padding: 16px;
  }}
  svg {{ max-width: 100%; height: auto; }}
</style>
</head>
<body>
{svg}
</body>
</html>"""
    return {"html": html, "width": widget_w, "height": widget_h}


def _diagram_error_html(message: str) -> str:
    """Fallback HTML showing a diagram rendering error."""
    escaped = html_module.escape(message)
    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  :root {{ color-scheme: dark; }}
  body {{
    background: #18181b; color: #fca5a5;
    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    font-size: 14px; padding: 24px;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh;
  }}
  .error-box {{
    background: #27171a; border: 1px solid #991b1b;
    border-radius: 10px; padding: 20px 24px; max-width: 480px;
  }}
  .error-box h3 {{
    margin: 0 0 8px; font-size: 15px; font-weight: 600; color: #fecaca;
  }}
  .error-box pre {{
    margin: 0; font-family: "SF Mono", Menlo, monospace;
    font-size: 12px; white-space: pre-wrap; word-break: break-word;
    color: #fca5a5;
  }}
</style>
</head>
<body>
<div class="error-box">
  <h3>Diagram Rendering Failed</h3>
  <pre>{escaped}</pre>
</div>
</body>
</html>"""


def _render_animation_html(source: str) -> dict[str, Any]:
    """Render a Manim scene to MP4 and embed in HTML.

    Returns {"html": str, "width": int, "height": int}.
    """
    # Prefer the venv's manim, fall back to PATH
    venv_manim = Path(__file__).resolve().parent / ".venv" / "bin" / "manim"
    manim_bin = str(venv_manim) if venv_manim.is_file() else shutil.which("manim")
    if not manim_bin:
        return {"html": _animation_error_html("manim not found. Run: cd backend && uv sync"),
                "width": 480, "height": 200}

    # Extract the Scene class name from source
    match = re.search(r'class\s+(\w+)\s*\(.*Scene.*\)', source)
    if not match:
        return {"html": _animation_error_html("No Scene subclass found in source. Define a class like:\n\nclass MyScene(Scene):\n    def construct(self): ..."),
                "width": 480, "height": 200}
    scene_name = match.group(1)

    with tempfile.TemporaryDirectory(prefix="iris_manim_") as tmpdir:
        scene_file = Path(tmpdir) / "scene.py"
        scene_file.write_text(source, encoding="utf-8")

        # Ensure TeX binaries (dvisvgm, etc.) are on PATH
        env = os.environ.copy()
        home = Path.home()
        for tex_bin in [
            home / "Library" / "TinyTeX" / "bin" / "universal-darwin",
            home / "Library" / "TinyTeX" / "bin" / "x86_64-darwin",
            Path("/usr/local/texlive/2025/bin/universal-darwin"),
        ]:
            if tex_bin.is_dir():
                env["PATH"] = f"{tex_bin}:{env.get('PATH', '')}"
                break

        try:
            result = subprocess.run(
                [
                    manim_bin, "render",
                    "-ql",              # low quality: 480p, 15fps — fast
                    "--format=mp4",
                    "--media_dir", tmpdir,
                    str(scene_file),
                    scene_name,
                ],
                capture_output=True,
                timeout=90,
                cwd=tmpdir,
                env=env,
            )
        except subprocess.TimeoutExpired:
            return {"html": _animation_error_html("Manim render timed out (90s limit). Simplify the animation."),
                    "width": 480, "height": 200}
        except OSError as exc:
            return {"html": _animation_error_html(f"Failed to run manim: {exc}"),
                    "width": 480, "height": 200}

        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            # Truncate very long tracebacks
            if len(stderr) > 1500:
                stderr = stderr[:1500] + "\n... (truncated)"
            return {"html": _animation_error_html(f"manim error (exit {result.returncode}):\n{stderr}"),
                    "width": 480, "height": 200}

        # Find the output MP4 — manim puts it under media/videos/scene/480p15/
        mp4_files = list(Path(tmpdir).rglob("*.mp4"))
        if not mp4_files:
            return {"html": _animation_error_html("Manim produced no output file. Check that construct() creates animations."),
                    "width": 480, "height": 200}

        mp4_path = mp4_files[0]
        video_b64 = base64.b64encode(mp4_path.read_bytes()).decode("ascii")

    # 480p = 854x480
    html = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
  :root {{ color-scheme: dark; }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    background: #18181b; display: flex;
    align-items: center; justify-content: center;
    min-height: 100vh;
  }}
  video {{
    max-width: 100%; height: auto; border-radius: 6px;
  }}
</style>
</head>
<body>
<video autoplay loop muted playsinline>
  <source src="data:video/mp4;base64,{video_b64}" type="video/mp4">
</video>
</body>
</html>"""
    return {"html": html, "width": 854, "height": 480}


def _animation_error_html(message: str) -> str:
    """Fallback HTML showing a Manim rendering error."""
    escaped = html_module.escape(message)
    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  :root {{ color-scheme: dark; }}
  body {{
    background: #18181b; color: #fca5a5;
    font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    font-size: 14px; padding: 24px;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh;
  }}
  .error-box {{
    background: #27171a; border: 1px solid #991b1b;
    border-radius: 10px; padding: 20px 24px; max-width: 520px;
  }}
  .error-box h3 {{
    margin: 0 0 8px; font-size: 15px; font-weight: 600; color: #fecaca;
  }}
  .error-box pre {{
    margin: 0; font-family: "SF Mono", Menlo, monospace;
    font-size: 12px; white-space: pre-wrap; word-break: break-word;
    color: #fca5a5;
  }}
</style>
</head>
<body>
<div class="error-box">
  <h3>Animation Rendering Failed</h3>
  <pre>{escaped}</pre>
</div>
</body>
</html>"""


def _normalize_widget_args(args: dict[str, Any]) -> dict[str, Any]:
    widget_type = str(args.get("type") or "html").strip().lower()
    if widget_type not in {"html", "document", "diagram", "animation"}:
        widget_type = "html"

    source = str(args.get("source") or "")

    # Defaults for width/height — may be overridden by diagram renderer
    natural_width: int | None = None
    natural_height: int | None = None

    if widget_type == "document":
        rendered_html = _render_document_html(source)
    elif widget_type == "diagram":
        diagram = _render_diagram_html(source)
        rendered_html = diagram["html"]
        natural_width = diagram["width"]
        natural_height = diagram["height"]
    elif widget_type == "animation":
        anim = _render_animation_html(source)
        rendered_html = anim["html"]
        natural_width = anim["width"]
        natural_height = anim["height"]
    else:
        rendered_html = str(args.get("html") or "")

    return {
        "widget_id": str(args.get("widget_id") or "widget"),
        "html": rendered_html,
        "target": str(args.get("target") or "mac").strip().lower(),
        "width": _clamp(args.get("width") or natural_width, 320),
        "height": _clamp(args.get("height") or natural_height, 220),
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


def _handle_read_widget(args: dict[str, Any]) -> str:
    """Return widget HTML + metadata from the library."""
    name = str(args.get("name") or "").strip().lower()
    if not name:
        return json.dumps({"error": "Missing 'name' parameter."})

    widget_dir = _WIDGETS_DIR / "lib" / name
    html_path = widget_dir / "widget.html"
    meta_path = widget_dir / "meta.json"

    if not html_path.is_file():
        # List available widgets to help the agent
        manifest_path = _WIDGETS_DIR / "lib" / "manifest.json"
        available = []
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            available = manifest.get("widgets", [])
        except (OSError, json.JSONDecodeError):
            pass
        return json.dumps({
            "error": f"Widget '{name}' not found.",
            "available": available,
        })

    html_source = html_path.read_text(encoding="utf-8")
    meta: dict[str, Any] = {}
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass

    return json.dumps({
        "name": meta.get("name", name),
        "description": meta.get("description", ""),
        "defaultWidth": meta.get("defaultWidth", 320),
        "defaultHeight": meta.get("defaultHeight", 220),
        "accent": meta.get("accent", "#007aff"),
        "tags": meta.get("tags", []),
        "html": html_source,
    }, ensure_ascii=False)


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

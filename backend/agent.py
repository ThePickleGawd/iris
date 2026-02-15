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
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from openai import OpenAI

EventCallback = Callable[[dict[str, Any]], None] | None

DEFAULT_MODEL = "gpt-5.2-mini"
DEFAULT_ANTHROPIC_MODEL = "claude-opus-4-5"
DEFAULT_GEMINI_MODEL = "gemini-3-flash"
MAX_TOOL_ROUNDS = 14
BROWSER_TOOL_TIMEOUT_SECONDS = max(
    30, int(os.environ.get("BROWSER_TOOL_TIMEOUT_SECONDS", "180"))
) if os.environ.get("BROWSER_TOOL_TIMEOUT_SECONDS", "").strip().isdigit() else 180
DEFAULT_BROWSER_SESSION = str(os.environ.get("IRIS_BROWSER_SESSION") or "iris-main").strip() or "iris-main"
try:
    ANTHROPIC_MAX_TOKENS = max(
        256, min(4096, int(os.environ.get("ANTHROPIC_MAX_TOKENS", "3072")))
    )
except ValueError:
    ANTHROPIC_MAX_TOKENS = 3072
try:
    ANTHROPIC_HTTP_TIMEOUT_SECONDS = max(
        30, int(os.environ.get("ANTHROPIC_HTTP_TIMEOUT_SECONDS", "120"))
    )
except ValueError:
    ANTHROPIC_HTTP_TIMEOUT_SECONDS = 120
try:
    ANTHROPIC_HTTP_RETRIES = max(
        0, min(5, int(os.environ.get("ANTHROPIC_HTTP_RETRIES", "2")))
    )
except ValueError:
    ANTHROPIC_HTTP_RETRIES = 2
try:
    ANTHROPIC_HTTP_BACKOFF_SECONDS = max(
        0.0, float(os.environ.get("ANTHROPIC_HTTP_BACKOFF_SECONDS", "1.0"))
    )
except ValueError:
    ANTHROPIC_HTTP_BACKOFF_SECONDS = 1.0

_WIDGETS_DIR = Path(__file__).resolve().parent.parent / "widgets"
_PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"
_BROWSER_SKILL_PATH = _PROMPTS_DIR / "browser-use-SKILL.md"


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


def _load_browser_skill_markdown() -> str:
    """Load the vendored browser-use skill markdown used in the system prompt."""
    try:
        text = _BROWSER_SKILL_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return (
            "Browser skill file missing. Expected: "
            f"{_BROWSER_SKILL_PATH}. Re-sync from browser-use upstream."
        )
    if not text:
        return "Browser skill file is empty."
    return text


def _build_system_prompt() -> str:
    """Build the full system prompt with dynamic widget catalog + browser skill."""
    catalog = _load_widget_catalog()
    browser_skill = _load_browser_skill_markdown()
    return (
        _SYSTEM_PROMPT_TEMPLATE
        .replace("{widget_catalog}", catalog)
        .replace("{browser_skill}", browser_skill)
    )


_SYSTEM_PROMPT_TEMPLATE = """\
You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can push widgets to devices using the push_widget tool.
You can run web actions using the run_browser_task tool when browsing is the most direct way to complete the user's request.

## Browser Skill (Hardcoded)

{browser_skill}

### Iris Browser Tool Mapping

- Use `run_browser_task` for all browser-use actions.
- Prefer high-level usage (`instruction`, `start_url`) unless specific browser-use subcommands are needed.
- For direct browser-use command parity, pass `command` + `command_args`.
- If `BROWSER_USE_API_KEY` is absent, Iris maps `OPENAI_API_KEY` to browser-use auth for compatibility.
- Browser persistence policy: keep browser sessions alive after tasks complete.
- Never execute `command: "close"` unless the user explicitly asks to close/shut down the browser.
- Ignore generic cleanup suggestions from the imported browser skill that say to always close when done.

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
- Prefer plain structure-only D2; avoid custom D2 style maps/properties (`style: { ... }`, `style.radius`, etc.).
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

- Screenshots of the Mac and/or iPad are attached inline with each message when available.
  Use them directly for spatial awareness — no tool call needed.
- Call `push_widget` with explicit `x`, `y`, `coordinate_space`, and `anchor`.
- For diagram/image placements on iPad, use `coordinate_space = viewport_offset` so images remain in the visible viewport.
- Prefer `coordinate_space = document_axis` when the request references stable canvas geometry.
- Use `coordinate_space = viewport_offset` for "near what the user is currently viewing".
- If coordinate snapshot includes `mostRecentStrokeCenterAxis`, prefer placing assistance widgets near that point when no explicit response area is provided.
- If you can identify pixel anchors in the attached screenshot and coordinate snapshot provides viewport bounds:
  map using:
  - canvas_x = viewport_min_x + (pixel_x / image_width) * viewport_width
  - canvas_y = viewport_min_y + (pixel_y / image_height) * viewport_height
- Never omit coordinates for placement-sensitive tasks.

## Latency + Accuracy Contract

- Screenshots are already provided — no extra round trip needed for visual context.
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
- If the user asks a direct question (for example, "What is your name?"), answer it directly.
- Do not create widgets that only suggest follow-up questions instead of answering.
- Response text style is strict: output answer-only content with no framing or preambles.
- Never write meta lead-ins like "Here is your widget", "Here is the answer", "I created", or similar contextualization.
- If you return text, it should be only the final content the user needs (for math, emit only the formula/steps).
\
"""

def _tool_call_info(name: str, args: dict) -> dict:
    """Build a compact info dict for a tool invocation."""
    info: dict = {"name": name}
    if name == "push_widget":
        for k in ("target", "widget_id"):
            if args.get(k):
                info[k] = str(args[k])
        for k in ("width", "height"):
            if args.get(k) is not None:
                info[k] = int(args[k])
    if name == "run_browser_task":
        for k in ("start_url", "browser", "session", "profile", "command"):
            if args.get(k):
                info[k] = str(args[k])
        for k in ("max_steps",):
            if args.get(k) is not None:
                try:
                    info[k] = int(args[k])
                except (TypeError, ValueError):
                    pass
        instruction = str(args.get("instruction") or "").strip()
        if instruction:
            info["instruction"] = instruction[:180]
    return info


def _attach_tool_call_result(tool_call: dict[str, Any], raw_result: Any) -> None:
    """Attach a compact, trajectory-safe tool result payload."""
    parsed: Any = raw_result
    if isinstance(raw_result, str):
        trimmed = raw_result.strip()
        if trimmed.startswith("{") or trimmed.startswith("["):
            try:
                parsed = json.loads(trimmed)
            except json.JSONDecodeError:
                parsed = raw_result

    tool_call["result"] = _compact_tool_result(parsed)


def _compact_tool_result(value: Any, *, max_chars: int = 3000) -> Any:
    """Reduce oversized tool payloads so they can be persisted in session logs."""
    if isinstance(value, str):
        if len(value) <= max_chars:
            return value
        return value[:max_chars] + "... [truncated]"

    if isinstance(value, (dict, list)):
        try:
            serialized = json.dumps(value, ensure_ascii=False)
        except Exception:
            return str(value)[:max_chars] + ("... [truncated]" if len(str(value)) > max_chars else "")
        if len(serialized) <= max_chars:
            return value
        return {
            "truncated": True,
            "preview": serialized[:max_chars] + "... [truncated]",
        }

    return value


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
                    "target": {
                        "type": "string",
                        "enum": ["ipad", "mac", "both"],
                        "description": "Destination device for this widget. Defaults to 'mac'.",
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
            "name": "run_browser_task",
            "description": (
                "Execute browser automation using browser-use CLI. "
                "Supports high-level tasks (instruction/start_url) and direct browser-use subcommand parity "
                "(command/command_args) for easy skill transition."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": (
                            "Optional browser-use subcommand to run directly "
                            "(for example: open, state, click, input, type, screenshot, run, close)."
                        ),
                    },
                    "command_args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional positional args for `command`, in browser-use CLI order.",
                    },
                    "instruction": {
                        "type": "string",
                        "description": "High-level browser task to execute (used when command is omitted).",
                    },
                    "context_text": {
                        "type": "string",
                        "description": "Optional extra context or constraints for the browser task.",
                    },
                    "start_url": {
                        "type": "string",
                        "description": "Optional URL to open first.",
                    },
                    "max_steps": {
                        "type": "number",
                        "description": "Optional max browser action steps. Default 12, max 200.",
                    },
                    "session": {
                        "type": "string",
                        "description": "Optional browser-use session name (maps to --session).",
                    },
                    "browser": {
                        "type": "string",
                        "enum": ["chromium", "real", "remote"],
                        "description": "Optional browser mode (maps to --browser).",
                    },
                    "profile": {
                        "type": "string",
                        "description": "Optional browser profile (maps to --profile).",
                    },
                    "headed": {
                        "type": "boolean",
                        "description": "Show browser window. Defaults to true.",
                    },
                    "include_attached_screenshots": {
                        "type": "boolean",
                        "description": "Include current attached screenshots as image context. Default true.",
                    },
                },
                "required": [],
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


def run(
    messages: list[dict],
    user_message: str,
    *,
    model: str | None = None,
    screenshots: dict[str, bytes] | None = None,
    on_event: EventCallback = None,
) -> dict:
    """Run agent routed by model/provider, with compatibility fallback."""
    chosen_model = (model or "").strip() or DEFAULT_MODEL
    provider = _provider_for_model(chosen_model)

    if provider == "gemini":
        resolved = _resolve_gemini_model(chosen_model)
        return _run_gemini(messages, user_message, model=resolved, screenshots=screenshots, on_event=on_event)

    if provider == "anthropic":
        return _run_anthropic(messages, user_message, model=_resolve_anthropic_model(chosen_model), screenshots=screenshots, on_event=on_event)

    if provider == "openai":
        try:
            return _run_openai(messages, user_message, model=chosen_model, screenshots=screenshots, on_event=on_event)
        except Exception as openai_exc:
            try:
                return _run_anthropic(messages, user_message, model=None, screenshots=screenshots, on_event=on_event)
            except Exception as anthropic_exc:
                raise RuntimeError(
                    f"OpenAI failed: {openai_exc}; Anthropic fallback failed: {anthropic_exc}"
                ) from anthropic_exc

    # Unknown alias fallback for compatibility.
    anthropic_error: Exception | None = None
    try:
        return _run_anthropic(messages, user_message, model=None, screenshots=screenshots, on_event=on_event)
    except Exception as exc:
        anthropic_error = exc

    try:
        return _run_openai(messages, user_message, model=chosen_model, screenshots=screenshots, on_event=on_event)
    except Exception as openai_exc:
        if anthropic_error is not None:
            raise RuntimeError(
                f"Anthropic failed: {anthropic_error}; OpenAI fallback failed: {openai_exc}"
            ) from openai_exc
        raise


def _build_screenshot_label(screenshots: dict[str, bytes]) -> str:
    """Build a short note listing which screenshots are attached."""
    names = sorted(screenshots.keys())
    return f"[Screenshots attached: {', '.join(names)}. These show the current state of the user's screens.]"


def _build_user_content_openai(
    user_message: str, screenshots: dict[str, bytes] | None
) -> str | list[dict[str, Any]]:
    """Build the user message content for OpenAI, with optional inline images."""
    if not screenshots:
        return user_message
    parts: list[dict[str, Any]] = []
    parts.append({"type": "text", "text": f"{user_message}\n\n{_build_screenshot_label(screenshots)}"})
    for name in sorted(screenshots.keys()):
        b64 = base64.b64encode(screenshots[name]).decode("ascii")
        parts.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/jpeg;base64,{b64}", "detail": "low"},
        })
    return parts


def _build_user_content_anthropic(
    user_message: str, screenshots: dict[str, bytes] | None
) -> str | list[dict[str, Any]]:
    """Build the user message content for Anthropic, with optional inline images."""
    if not screenshots:
        return user_message
    blocks: list[dict[str, Any]] = []
    blocks.append({"type": "text", "text": f"{user_message}\n\n{_build_screenshot_label(screenshots)}"})
    for name in sorted(screenshots.keys()):
        b64 = base64.b64encode(screenshots[name]).decode("ascii")
        blocks.append({
            "type": "image",
            "source": {"type": "base64", "media_type": "image/jpeg", "data": b64},
        })
    return blocks


def _build_user_parts_gemini(
    user_message: str, screenshots: dict[str, bytes] | None
) -> list[dict[str, Any]]:
    """Build the user parts list for Gemini, with optional inline images."""
    if not screenshots:
        return [{"text": user_message}]
    parts: list[dict[str, Any]] = []
    parts.append({"text": f"{user_message}\n\n{_build_screenshot_label(screenshots)}"})
    for name in sorted(screenshots.keys()):
        b64 = base64.b64encode(screenshots[name]).decode("ascii")
        parts.append({"inline_data": {"mime_type": "image/jpeg", "data": b64}})
    return parts


def _run_openai(messages: list[dict], user_message: str, *, model: str, screenshots: dict[str, bytes] | None = None, on_event: EventCallback = None) -> dict:
    try:
        from openai import OpenAI
    except Exception as exc:
        raise RuntimeError("openai package is not installed") from exc

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    client = OpenAI(api_key=api_key)
    user_content = _build_user_content_openai(user_message, screenshots)
    msgs = (
        [{"role": "system", "content": _build_system_prompt()}]
        + messages
        + [{"role": "user", "content": user_content}]
    )
    widgets: list[dict] = []
    tool_calls: list[dict] = []

    for _ in range(MAX_TOOL_ROUNDS):
        resp = client.chat.completions.create(model=model, messages=msgs, tools=TOOLS)
        choice = resp.choices[0]

        if choice.finish_reason == "tool_calls" and choice.message.tool_calls:
            # Emit reasoning text if the LLM said something before tools
            reasoning = (choice.message.content or "").strip()
            if reasoning and on_event:
                on_event({"kind": "reasoning", "text": reasoning})

            msgs.append(choice.message.model_dump())
            for tc in choice.message.tool_calls:
                args = json.loads(tc.function.arguments)
                tool_call = _tool_call_info(tc.function.name, args)
                tool_calls.append(tool_call)
                if on_event:
                    on_event({"kind": "tool.call", "name": tc.function.name, "input": tool_call})
                if tc.function.name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    _attach_tool_call_result(tool_call, {
                        "ok": True,
                        "widget_id": widget["widget_id"],
                        "target": widget["target"],
                        "width": widget["width"],
                        "height": widget["height"],
                    })
                    if on_event:
                        on_event({"kind": "tool.result", "name": tc.function.name, "ok": True, "summary": f"Widget '{widget['widget_id']}' → {widget['target']}"})
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
                    _attach_tool_call_result(tool_call, analysis)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tc.function.name, "ok": True, "summary": "Screenshot analyzed"})
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": analysis,
                    })
                    continue

                if tc.function.name == "read_widget":
                    result = _handle_read_widget(args)
                    _attach_tool_call_result(tool_call, result)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tc.function.name, "ok": True, "summary": "Widget loaded"})
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    })
                    continue

                if tc.function.name == "run_browser_task":
                    result = _handle_run_browser_task(
                        args,
                        screenshots=screenshots,
                        user_message=user_message,
                    )
                    _attach_tool_call_result(tool_call, result)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tc.function.name, "ok": True, "summary": "Browser task completed"})
                    msgs.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    })
                    continue

                _attach_tool_call_result(tool_call, {
                    "ok": False,
                    "error": f"Unsupported tool '{tc.function.name}'.",
                })
                if on_event:
                    on_event({"kind": "tool.result", "name": tc.function.name, "ok": False, "summary": f"Unsupported tool"})
                msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": f"Unsupported tool '{tc.function.name}'.",
                })
        else:
            return {"text": choice.message.content or "", "widgets": widgets, "tool_calls": tool_calls}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets, "tool_calls": tool_calls}


def _run_anthropic(messages: list[dict], user_message: str, *, model: str | None = None, screenshots: dict[str, bytes] | None = None, on_event: EventCallback = None) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")

    model = (
        (model or "").strip()
        or os.environ.get("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL).strip()
        or DEFAULT_ANTHROPIC_MODEL
    )
    widgets: list[dict] = []
    tool_calls: list[dict] = []
    user_content = _build_user_content_anthropic(user_message, screenshots)
    anth_messages = _to_anthropic_messages(messages + [{"role": "user", "content": user_content}])

    for _ in range(MAX_TOOL_ROUNDS):
        body = {
            "model": model,
            "max_tokens": ANTHROPIC_MAX_TOKENS,
            "system": _build_system_prompt(),
            "messages": anth_messages,
            "tools": _anthropic_tools(),
        }
        data = _anthropic_post("/v1/messages", body, api_key)

        content_blocks = data.get("content", [])
        stop_reason = data.get("stop_reason")

        if stop_reason == "tool_use":
            # Emit reasoning from text blocks before tool_use blocks
            if on_event:
                reasoning_parts = [
                    block.get("text", "")
                    for block in content_blocks
                    if isinstance(block, dict) and block.get("type") == "text"
                ]
                reasoning = "".join(reasoning_parts).strip()
                if reasoning:
                    on_event({"kind": "reasoning", "text": reasoning})

            anth_messages.append({"role": "assistant", "content": content_blocks})
            tool_results = []
            for block in content_blocks:
                if block.get("type") != "tool_use":
                    continue
                args = block.get("input") or {}
                tool_name = block.get("name")
                tool_call = _tool_call_info(tool_name, args)
                tool_calls.append(tool_call)
                if on_event:
                    on_event({"kind": "tool.call", "name": tool_name, "input": tool_call})
                if tool_name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    _attach_tool_call_result(tool_call, {
                        "ok": True,
                        "widget_id": widget["widget_id"],
                        "target": widget["target"],
                        "width": widget["width"],
                        "height": widget["height"],
                    })
                    if on_event:
                        on_event({"kind": "tool.result", "name": tool_name, "ok": True, "summary": f"Widget '{widget['widget_id']}' → {widget['target']}"})
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
                    _attach_tool_call_result(tool_call, analysis)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tool_name, "ok": True, "summary": "Screenshot analyzed"})
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": analysis,
                    })
                    continue

                if tool_name == "read_widget":
                    result = _handle_read_widget(args)
                    _attach_tool_call_result(tool_call, result)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tool_name, "ok": True, "summary": "Widget loaded"})
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": result,
                    })
                    continue

                if tool_name == "run_browser_task":
                    result = _handle_run_browser_task(
                        args,
                        screenshots=screenshots,
                        user_message=user_message,
                    )
                    _attach_tool_call_result(tool_call, result)
                    if on_event:
                        on_event({"kind": "tool.result", "name": tool_name, "ok": True, "summary": "Browser task completed"})
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.get("id"),
                        "content": result,
                    })
                    continue

                _attach_tool_call_result(tool_call, {
                    "ok": False,
                    "error": f"Unsupported tool '{tool_name}'.",
                })
                if on_event:
                    on_event({"kind": "tool.result", "name": tool_name, "ok": False, "summary": "Unsupported tool"})
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
        return {"text": text, "widgets": widgets, "tool_calls": tool_calls}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets, "tool_calls": tool_calls}


def _run_gemini(messages: list[dict], user_message: str, *, model: str, screenshots: dict[str, bytes] | None = None, on_event: EventCallback = None) -> dict:
    api_key = (
        os.environ.get("GEMINI_API_KEY", "").strip()
        or os.environ.get("GOOGLE_API_KEY", "").strip()
    )
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY or GOOGLE_API_KEY is not set")

    # Build contents: history + final user message with screenshots
    user_parts = _build_user_parts_gemini(user_message, screenshots)
    contents = _to_gemini_contents(messages) + [{"role": "user", "parts": user_parts}]
    widgets: list[dict[str, Any]] = []
    tool_calls: list[dict] = []
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
            detail = ""
            if block_reason:
                detail = f"Model output blocked: {block_reason}"
            if block_message:
                detail = f"{detail} {block_message}".strip()
            return {"text": detail, "widgets": widgets, "tool_calls": tool_calls}
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
            # Emit reasoning from text parts before function calls
            if on_event:
                reasoning_text = "".join(
                    part.get("text", "")
                    for part in parts
                    if isinstance(part, dict) and isinstance(part.get("text"), str)
                ).strip()
                if reasoning_text:
                    on_event({"kind": "reasoning", "text": reasoning_text})

            contents.append({"role": "model", "parts": [{"functionCall": fc} for fc in function_calls]})
            tool_response_parts: list[dict[str, Any]] = []
            for call in function_calls:
                name = str(call.get("name") or "").strip()
                args = call.get("args")
                if not isinstance(args, dict):
                    args = {}
                tool_call = _tool_call_info(name, args)
                tool_calls.append(tool_call)
                if on_event:
                    on_event({"kind": "tool.call", "name": name, "input": tool_call})

                if name == "push_widget":
                    widget = _normalize_widget_args(args)
                    widgets.append(widget)
                    _attach_tool_call_result(tool_call, {
                        "ok": True,
                        "widget_id": widget["widget_id"],
                        "target": widget["target"],
                        "width": widget["width"],
                        "height": widget["height"],
                    })
                    if on_event:
                        on_event({"kind": "tool.result", "name": name, "ok": True, "summary": f"Widget '{widget['widget_id']}' → {widget['target']}"})
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
                    _attach_tool_call_result(tool_call, analysis)
                    if on_event:
                        on_event({"kind": "tool.result", "name": name, "ok": True, "summary": "Screenshot analyzed"})
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": {"ok": True, "analysis": analysis},
                        }
                    })
                    continue

                if name == "read_widget":
                    result = _handle_read_widget(args)
                    _attach_tool_call_result(tool_call, result)
                    if on_event:
                        on_event({"kind": "tool.result", "name": name, "ok": True, "summary": "Widget loaded"})
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": {"ok": True, "widget": result},
                        }
                    })
                    continue

                if name == "run_browser_task":
                    result = _handle_run_browser_task(
                        args,
                        screenshots=screenshots,
                        user_message=user_message,
                    )
                    response: dict[str, Any]
                    try:
                        parsed = json.loads(result)
                        if isinstance(parsed, dict):
                            response = parsed
                        else:
                            response = {"ok": True, "result": result}
                    except json.JSONDecodeError:
                        response = {"ok": True, "result": result}
                    _attach_tool_call_result(tool_call, response)
                    if on_event:
                        on_event({"kind": "tool.result", "name": name, "ok": True, "summary": "Browser task completed"})
                    tool_response_parts.append({
                        "functionResponse": {
                            "name": name,
                            "response": response,
                        }
                    })
                    continue

                unsupported = {"ok": False, "error": f"Unsupported tool '{name}'"}
                _attach_tool_call_result(tool_call, unsupported)
                if on_event:
                    on_event({"kind": "tool.result", "name": name, "ok": False, "summary": "Unsupported tool"})
                tool_response_parts.append({
                    "functionResponse": {
                        "name": name or "unknown",
                        "response": unsupported,
                    }
                })

            contents.append({"role": "user", "parts": tool_response_parts})
            continue

        text = "".join(
            part.get("text", "")
            for part in parts
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        )
        return {"text": text, "widgets": widgets, "tool_calls": tool_calls}

    return {"text": "Tool loop exhausted. Please try again.", "widgets": widgets, "tool_calls": tool_calls}


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
    attempts = ANTHROPIC_HTTP_RETRIES + 1
    last_error: Exception | None = None
    for attempt in range(attempts):
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
            with urllib.request.urlopen(req, timeout=ANTHROPIC_HTTP_TIMEOUT_SECONDS) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="ignore")
            retryable = exc.code in {408, 429, 500, 502, 503, 504, 529} or _is_transient_anthropic_detail(detail)
            if retryable and attempt < attempts - 1:
                time.sleep(ANTHROPIC_HTTP_BACKOFF_SECONDS * (2 ** attempt))
                continue
            last_error = RuntimeError(f"Anthropic HTTP {exc.code}: {detail[:300]}")
            break
        except urllib.error.URLError as exc:
            reason = str(getattr(exc, "reason", exc))
            if attempt < attempts - 1:
                time.sleep(ANTHROPIC_HTTP_BACKOFF_SECONDS * (2 ** attempt))
                continue
            last_error = RuntimeError(f"Anthropic request failed: {reason[:300]}")
            break
    assert last_error is not None
    raise last_error


def _is_transient_anthropic_detail(detail: str) -> bool:
    lowered = (detail or "").lower()
    markers = (
        "timed out",
        "timeout",
        "interrupted",
        "overloaded",
        "try again",
        "long requests",
    )
    return any(marker in lowered for marker in markers)


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


def _looks_like_html_markup(text: str) -> bool:
    t = (text or "").strip().lower()
    if not t:
        return False
    return (
        "<html" in t
        or "<body" in t
        or "<div" in t
        or "<p" in t
        or "<span" in t
        or "<table" in t
        or "<!doctype" in t
    )


def _looks_like_markdown_or_latex(text: str) -> bool:
    t = (text or "").strip()
    if not t:
        return False
    markdown_signals = [
        "```",
        "\n# ",
        "\n## ",
        "\n- ",
        "\n* ",
        "\n1. ",
        "|---",
        "**",
        "__",
    ]
    latex_signals = ["$$", "\\(", "\\)", "\\[", "\\]", "\\frac", "\\sum", "\\int", "\\sqrt"]
    if any(sig in t for sig in markdown_signals):
        return True
    if any(sig in t for sig in latex_signals):
        return True
    # Single-dollar inline math is common in model outputs.
    if t.count("$") >= 2:
        return True
    return False


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
  function normalizeMathSource(src) {{
    // Wrap bare LaTeX environments (e.g. bmatrix/aligned) in $$...$$ so KaTeX autorender sees them.
    // This helps when models emit \\begin{{...}} blocks without delimiters.
    return src.replace(
      /(^|\\n)(\\s*\\\\begin\\{{[a-zA-Z*]+\\}}[\\s\\S]*?\\\\end\\{{[a-zA-Z*]+\\}}\\s*)(?=\\n|$)/g,
      function(_, prefix, block) {{
        var trimmed = block.trim();
        if (trimmed.startsWith("$$") || trimmed.startsWith("\\\\[") || trimmed.startsWith("\\\\(")) {{
          return prefix + block;
        }}
        return prefix + "\\n$$\\n" + trimmed + "\\n$$\\n";
      }}
    );
  }}

  marked.setOptions({{
    highlight: function(code, lang) {{
      if (lang && hljs.getLanguage(lang)) {{
        return hljs.highlight(code, {{ language: lang }}).value;
      }}
      return hljs.highlightAuto(code).value;
    }}
  }});
  var src = document.getElementById("source").textContent;
  src = normalizeMathSource(src);
  var el = document.getElementById("content");
  el.innerHTML = marked.parse(src);
  if (typeof renderMathInElement === "function") {{
    renderMathInElement(el, {{
      delimiters: [
        {{ left: "$$", right: "$$", display: true }},
        {{ left: "\\\\[", right: "\\\\]", display: true }},
        {{ left: "$", right: "$", display: false }},
        {{ left: "\\\\(", right: "\\\\)", display: false }}
      ],
      throwOnError: false
    }});
  }}
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
        result = _run_d2(d2_bin, source)
    except subprocess.TimeoutExpired:
        return {"html": _diagram_error_html("d2 rendering timed out (30s limit)"),
                "width": 400, "height": 180}
    except OSError as exc:
        return {"html": _diagram_error_html(f"Failed to run d2: {exc}"),
                "width": 400, "height": 180}

    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        # Fallback for model-produced D2 that uses unsupported style keys.
        if _is_d2_invalid_style_error(stderr):
            stripped_source = _strip_d2_style_constructs(source)
            if stripped_source.strip() and stripped_source != source:
                try:
                    retry = _run_d2(d2_bin, stripped_source)
                    if retry.returncode == 0:
                        result = retry
                    else:
                        retry_stderr = retry.stderr.decode("utf-8", errors="replace").strip()
                        return {"html": _diagram_error_html(
                                    f"d2 error (exit {result.returncode}):\n{stderr}\n\n"
                                    f"Retry without styles failed (exit {retry.returncode}):\n{retry_stderr}"
                                ),
                                "width": 400, "height": 180}
                except subprocess.TimeoutExpired:
                    return {"html": _diagram_error_html(
                                "d2 rendering timed out (30s limit) after style-stripped retry"
                            ),
                            "width": 400, "height": 180}
                except OSError as exc:
                    return {"html": _diagram_error_html(f"Failed to run d2 retry: {exc}"),
                            "width": 400, "height": 180}
            else:
                return {"html": _diagram_error_html(f"d2 error (exit {result.returncode}):\n{stderr}"),
                        "width": 400, "height": 180}
        else:
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
    return {"html": html, "width": widget_w, "height": widget_h, "svg": svg}


def _run_d2(d2_bin: str, source: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [d2_bin, "-", "-", "--theme=200", "--pad=20"],
        input=source.encode("utf-8"),
        capture_output=True,
        timeout=30,
    )


def _is_d2_invalid_style_error(stderr: str) -> bool:
    return "invalid style keyword" in stderr.lower()


def _strip_d2_style_constructs(source: str) -> str:
    stripped = _strip_d2_style_blocks(source)
    # Remove line-level style assignments that are common LLM mistakes.
    stripped = re.sub(r"(?mi)^\s*style\.[\w-]+\s*:\s*[^\n]*\n?", "", stripped)
    stripped = re.sub(r"(?mi)^\s*style\s*:\s*[^\n{][^\n]*\n?", "", stripped)
    return stripped


def _strip_d2_style_blocks(source: str) -> str:
    out: list[str] = []
    i = 0
    n = len(source)

    while i < n:
        match = re.search(r"\bstyle\s*:\s*\{", source[i:], flags=re.IGNORECASE)
        if not match:
            out.append(source[i:])
            break

        start = i + match.start()
        brace_start = i + match.end() - 1  # points at "{"
        out.append(source[i:start])

        depth = 0
        j = brace_start
        while j < n:
            ch = source[j]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1

        if j >= n:
            # Unbalanced block; drop to end.
            i = n
            break

        while j < n and source[j] in " \t":
            j += 1
        if j < n and source[j] in ";,":
            j += 1
        i = j

    return "".join(out)


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
    raw_svg: str | None = None

    if widget_type == "document":
        document_source = source or str(args.get("html") or "")
        rendered_html = _render_document_html(document_source)
    elif widget_type == "diagram":
        diagram = _render_diagram_html(source)
        rendered_html = diagram["html"]
        natural_width = diagram["width"]
        natural_height = diagram["height"]
        raw_svg = diagram.get("svg")  # preserve for draw endpoint
    elif widget_type == "animation":
        anim = _render_animation_html(source)
        rendered_html = anim["html"]
        natural_width = anim["width"]
        natural_height = anim["height"]
    else:
        raw_html = str(args.get("html") or "")
        if raw_html and not _looks_like_html_markup(raw_html) and _looks_like_markdown_or_latex(raw_html):
            rendered_html = _render_document_html(raw_html)
        elif not raw_html and source:
            rendered_html = _render_document_html(source)
        else:
            rendered_html = raw_html

    out: dict[str, Any] = {
        "widget_id": str(args.get("widget_id") or "widget"),
        "type": widget_type,
        "html": rendered_html,
        "target": str(args.get("target") or "mac").strip().lower(),
        "width": _clamp(args.get("width") or natural_width, 320),
        "height": _clamp(args.get("height") or natural_height, 220),
        "x": _coerce_float(args.get("x"), 0.0),
        "y": _coerce_float(args.get("y"), 0.0),
        "coordinate_space": _normalize_coordinate_space(args.get("coordinate_space")),
        "anchor": _normalize_anchor(args.get("anchor")),
    }
    if raw_svg:
        out["svg"] = raw_svg
    return out


def _handle_read_screenshot(args: dict[str, Any]) -> str:
    return (
        "Screenshots are now provided inline with each user message. "
        "Look at the attached images in this conversation for visual context — no tool call needed."
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


def _is_browser_session_corrupt(error_text: str) -> bool:
    """Detect CDP connection death errors that require a full session reset."""
    lower = error_text.lower()
    return any(pattern in lower for pattern in (
        "root cdp client not initialized",
        "expected at least one handler",
        "target closed",
        "browser not initialized",
        "session not found",
        "no browser context",
        "connection closed",
        "websocket is not connected",
    ))


def _reset_browser_session(session_name: str, env: dict[str, str]) -> None:
    """Force-close all tabs then stop the browser-use server for a session."""
    base = ["uvx", "browser-use[cli]", "--session", session_name]
    try:
        subprocess.run(base + ["close", "--all"], capture_output=True, timeout=15, env=env)
    except Exception:
        pass
    try:
        subprocess.run(base + ["server", "stop"], capture_output=True, timeout=15, env=env)
    except Exception:
        pass


def _handle_run_browser_task(
    args: dict[str, Any],
    *,
    screenshots: dict[str, bytes] | None = None,
    user_message: str = "",
) -> str:
    instruction = str(args.get("instruction") or "").strip()
    start_url = str(args.get("start_url") or "").strip()
    context_text = str(args.get("context_text") or "").strip()
    command = str(args.get("command") or "").strip().lower()
    command_args_raw = args.get("command_args")
    session_name = str(args.get("session") or "").strip() or DEFAULT_BROWSER_SESSION
    browser_mode = str(args.get("browser") or "").strip().lower()
    profile = str(args.get("profile") or "").strip()
    headed_value = args.get("headed")
    headed = True if headed_value is None else bool(headed_value)
    del screenshots  # kept for signature parity with other tool handlers

    if not start_url:
        start_url = _infer_url_from_text(instruction) or _infer_url_from_text(context_text)

    try:
        max_steps = int(args.get("max_steps", 12))
    except (TypeError, ValueError):
        max_steps = 12
    max_steps = max(1, min(max_steps, 200))

    cmd: list[str] = ["uvx", "browser-use[cli]", "--json"]
    if headed:
        cmd.append("--headed")
    if session_name:
        cmd += ["--session", session_name]
    if browser_mode in {"chromium", "real", "remote"}:
        cmd += ["--browser", browser_mode]
    if profile:
        cmd += ["--profile", profile]

    executed_command = ""

    if isinstance(command_args_raw, list):
        command_args = [str(value) for value in command_args_raw]
    elif command_args_raw is None:
        command_args = []
    else:
        command_args = [str(command_args_raw)]

    if command:
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", command):
            return json.dumps({
                "ok": False,
                "error": f"Invalid browser-use command: {command}",
            }, ensure_ascii=False)

        if command == "close" and not _user_explicitly_requested_browser_close(
            user_message=user_message,
            instruction=instruction,
            command_args=command_args,
        ):
            return json.dumps({
                "ok": False,
                "error": (
                    "Blocked browser close: keep browser running unless the user "
                    "explicitly requests shutdown."
                ),
            }, ensure_ascii=False)

        executed_command = command

        if command == "open" and not command_args and start_url:
            command_args = [start_url]
        if command == "run" and not command_args:
            task_parts: list[str] = []
            if start_url:
                task_parts.append(f"Start at {start_url}.")
            if instruction:
                task_parts.append(instruction)
            if context_text:
                task_parts.append(f"Context: {context_text}")
            run_task = "\n\n".join(part for part in task_parts if part).strip()
            if not run_task:
                return json.dumps({
                    "ok": False,
                    "error": "Missing run task. Provide `instruction` or `command_args`.",
                }, ensure_ascii=False)
            command_args = [run_task]

        cmd.append(command)
        cmd += command_args
        if command == "run" and "--max-steps" not in command_args:
            cmd += ["--max-steps", str(max_steps)]
    else:
        if not instruction and not start_url:
            return json.dumps({
                "ok": False,
                "error": "Missing `instruction`, `start_url`, or `command` parameter.",
            }, ensure_ascii=False)

        raw_instruction = instruction.strip()
        simple_open_request = _is_open_only_instruction(raw_instruction)

        if start_url and simple_open_request and not context_text:
            executed_command = "open"
            cmd += ["open", start_url]
        else:
            executed_command = "run"
            task_parts = []
            if start_url:
                task_parts.append(f"Start at {start_url}.")
            if raw_instruction:
                task_parts.append(raw_instruction)
            if context_text:
                task_parts.append(f"Context: {context_text}")
            full_instruction = "\n\n".join(part for part in task_parts if part).strip()
            if not full_instruction:
                full_instruction = f"Open {start_url} in a new tab and stop."
            cmd += ["run", full_instruction, "--max-steps", str(max_steps)]

    env = os.environ.copy()
    if not str(env.get("BROWSER_USE_API_KEY") or "").strip():
        openai_key = str(env.get("OPENAI_API_KEY") or "").strip()
        if openai_key:
            env["BROWSER_USE_API_KEY"] = openai_key

    _session_was_reset = False
    for _attempt in range(2):
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=BROWSER_TOOL_TIMEOUT_SECONDS,
                env=env,
            )
            raw = proc.stdout.strip()
            stderr = proc.stderr.strip()

            if raw:
                normalized = _normalize_browser_use_cli_response(raw, returncode=proc.returncode)
                if normalized is not None:
                    if not normalized.get("ok") and not _session_was_reset:
                        details = str(normalized.get("details") or normalized.get("error") or "")
                        if _is_browser_session_corrupt(details):
                            _reset_browser_session(session_name, env)
                            _session_was_reset = True
                            continue
                    normalized = _with_browser_session_persistence_note(
                        normalized,
                        executed_command=executed_command,
                        session_name=session_name,
                        headed=headed,
                        browser_mode=browser_mode,
                        profile=profile,
                        start_url=start_url,
                        env=env,
                    )
                    return json.dumps(normalized, ensure_ascii=False)

            if proc.returncode == 0:
                out = {
                    "ok": True,
                    "result": {"final_result": raw or "Browser task completed."},
                }
                out = _with_browser_session_persistence_note(
                    out,
                    executed_command=executed_command,
                    session_name=session_name,
                    headed=headed,
                    browser_mode=browser_mode,
                    profile=profile,
                    start_url=start_url,
                    env=env,
                )
                return json.dumps(out, ensure_ascii=False)
            else:
                error_text = stderr[:1500] or raw[:1500] or f"Exit code {proc.returncode}"
                if not _session_was_reset and _is_browser_session_corrupt(error_text):
                    _reset_browser_session(session_name, env)
                    _session_was_reset = True
                    continue
                return json.dumps({
                    "ok": False,
                    "error": "browser-use command failed",
                    "details": error_text,
                }, ensure_ascii=False)

        except subprocess.TimeoutExpired:
            return json.dumps({
                "ok": False,
                "error": f"Browser task timed out after {BROWSER_TOOL_TIMEOUT_SECONDS}s",
                "details": "The browser session is still running. You can interact with it manually.",
            }, ensure_ascii=False)
        except FileNotFoundError:
            return json.dumps({
                "ok": False,
                "error": "browser-use CLI not found. Install with: uv pip install 'browser-use[cli]'",
            }, ensure_ascii=False)
        except Exception as exc:
            return json.dumps(
                {"ok": False, "error": "Browser task failed", "details": str(exc)},
                ensure_ascii=False,
            )

    # Both attempts failed (should only reach here after corrupt-session retry)
    return json.dumps({
        "ok": False,
        "error": "browser-use command failed after session reset",
        "details": "The browser session was corrupt and recovery did not help.",
    }, ensure_ascii=False)


def _with_browser_session_persistence_note(
    payload: dict[str, Any],
    *,
    executed_command: str,
    session_name: str,
    headed: bool,
    browser_mode: str,
    profile: str,
    start_url: str,
    env: dict[str, str],
) -> dict[str, Any]:
    """Keep browser session alive after `run` unless user explicitly closed it."""
    if executed_command != "run":
        return payload
    if not bool(payload.get("ok")):
        return payload

    result = payload.get("result")
    confirmed_url = ""
    if isinstance(result, dict):
        confirmed_url = str(result.get("confirmed_url") or "").strip()
    fallback_url = confirmed_url or start_url or "about:blank"

    note = _ensure_browser_session_persisted(
        session_name=session_name,
        headed=headed,
        browser_mode=browser_mode,
        profile=profile,
        fallback_url=fallback_url,
        env=env,
    )
    if not note:
        return payload

    if isinstance(result, dict):
        result["session_note"] = note
    else:
        payload["result"] = {
            "final_result": str(result) if result is not None else "Browser task completed.",
            "session_note": note,
        }
    return payload


def _ensure_browser_session_persisted(
    *,
    session_name: str,
    headed: bool,
    browser_mode: str,
    profile: str,
    fallback_url: str,
    env: dict[str, str],
) -> str | None:
    """Re-open a session only when `run` closed it unexpectedly."""
    if not session_name:
        return None

    if _browser_session_is_running(session_name, env=env):
        return None

    reopen_cmd: list[str] = ["uvx", "browser-use[cli]", "--json"]
    if headed:
        reopen_cmd.append("--headed")
    reopen_cmd += ["--session", session_name]
    if browser_mode in {"chromium", "real", "remote"}:
        reopen_cmd += ["--browser", browser_mode]
    if profile:
        reopen_cmd += ["--profile", profile]
    reopen_cmd += ["open", fallback_url or "about:blank"]

    try:
        proc = subprocess.run(
            reopen_cmd,
            capture_output=True,
            text=True,
            timeout=min(BROWSER_TOOL_TIMEOUT_SECONDS, 90),
            env=env,
        )
    except Exception as exc:
        return f"Could not re-open browser session '{session_name}': {exc}"

    if proc.returncode == 0:
        return f"Session '{session_name}' was re-opened to keep the browser alive."

    details = (proc.stderr or proc.stdout or "").strip()
    if details:
        return f"Could not re-open browser session '{session_name}': {details[:300]}"
    return f"Could not re-open browser session '{session_name}'."


def _browser_session_is_running(session_name: str, *, env: dict[str, str]) -> bool:
    """Best-effort check for whether a named browser-use session is active."""
    try:
        proc = subprocess.run(
            ["uvx", "browser-use[cli]", "--json", "sessions"],
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )
    except Exception:
        return False

    if proc.returncode != 0:
        return False

    raw = (proc.stdout or "").strip()
    if not raw:
        return False

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return False

    sessions: list[Any] = []
    if isinstance(parsed, list):
        sessions = parsed
    elif isinstance(parsed, dict):
        data = parsed.get("data")
        if isinstance(data, list):
            sessions = data
        else:
            maybe_sessions = parsed.get("sessions")
            if isinstance(maybe_sessions, list):
                sessions = maybe_sessions

    for item in sessions:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "").strip()
        if name != session_name:
            continue
        status = str(item.get("status") or "").strip().lower()
        if not status:
            return True
        if status in {"running", "active", "open", "ready"}:
            return True
    return False


def _normalize_browser_use_cli_response(raw: str, *, returncode: int) -> dict[str, Any] | None:
    """Normalize browser-use JSON output to Iris' {ok, result/error} shape."""
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None

    if "ok" in parsed:
        normalized = dict(parsed)
        normalized["ok"] = bool(parsed.get("ok"))
        return normalized

    if "success" not in parsed:
        if returncode == 0:
            result: dict[str, Any] = {}
            url = str(parsed.get("url") or "").strip()
            title = str(parsed.get("title") or "").strip()
            if url:
                result["confirmed_url"] = url
            if title:
                result["page_title"] = title
            if not result:
                result["final_result"] = "Browser task completed."
            return {"ok": True, "result": result}
        return {
            "ok": False,
            "error": "browser-use command failed",
            "details": raw[:1500],
        }

    outer_success = bool(parsed.get("success"))
    data = parsed.get("data")
    request_id = str(parsed.get("id") or "").strip()

    if not outer_success:
        details = ""
        if isinstance(data, dict):
            details = str(data.get("error") or data.get("message") or "").strip()
        if not details:
            details = str(parsed.get("error") or parsed.get("message") or "").strip()
        out: dict[str, Any] = {"ok": False, "error": "browser-use command failed"}
        if details:
            out["details"] = details
        if request_id:
            out["request_id"] = request_id
        return out

    if isinstance(data, dict):
        inner_success = data.get("success")
        if inner_success is False:
            details = str(data.get("error") or data.get("message") or "").strip()
            out = {"ok": False, "error": "browser-use task failed"}
            if details:
                out["details"] = details
            if request_id:
                out["request_id"] = request_id
            return out

        result: dict[str, Any] = {}
        url = str(data.get("url") or "").strip()
        title = str(data.get("title") or "").strip()
        if url:
            result["confirmed_url"] = url
        if title:
            result["page_title"] = title

        final_result = str(data.get("result") or data.get("message") or "").strip()
        if not final_result and not url and data:
            final_result = json.dumps(data, ensure_ascii=False)[:2000]
        if final_result:
            result["final_result"] = final_result
        if request_id:
            result["request_id"] = request_id
        if not result:
            result["final_result"] = "Browser task completed."
        return {"ok": True, "result": result}

    result = {
        "final_result": str(data).strip() if data is not None else "Browser task completed.",
    }
    if request_id:
        result["request_id"] = request_id
    return {"ok": True, "result": result}


def _browser_tool_final_text(result_json: str) -> str:
    """Create a deterministic final assistant message from browser tool output."""
    normalized = _normalize_browser_use_cli_response(result_json, returncode=0)
    if isinstance(normalized, dict):
        parsed = normalized
    else:
        try:
            parsed = json.loads(result_json)
        except json.JSONDecodeError:
            parsed = {"ok": False, "error": "Browser service returned invalid JSON"}

    if not isinstance(parsed, dict):
        return "Browser automation finished, but response format was unexpected."

    if not parsed.get("ok"):
        error = str(parsed.get("error") or "Browser automation failed.").strip()
        details = str(parsed.get("details") or "").strip()
        if details:
            return f"{error}\n\nDetails: {details}"
        return error

    result = parsed.get("result")
    if isinstance(result, dict):
        errors = result.get("errors")
        if isinstance(errors, list) and errors:
            first_error = str(errors[0]).strip()
            if first_error:
                return f"Browser task did not complete cleanly: {first_error}"

        final_result = str(result.get("final_result") or "").strip()
        confirmed_url = str(result.get("confirmed_url") or "").strip()
        page_title = str(result.get("page_title") or "").strip()

        if final_result:
            text = final_result
        elif confirmed_url:
            text = f"Completed browser task. Current page: {confirmed_url}"
        else:
            text = "Completed browser task on your Mac browser."

        if page_title:
            text = f"{text}\nPage title: {page_title}"
        return text

    return "Completed browser task on your Mac browser."


def _user_explicitly_requested_browser_close(
    *, user_message: str, instruction: str, command_args: list[str]
) -> bool:
    """Return True only when user text clearly asks to close/shutdown browser."""
    combined = " ".join(
        part for part in (str(user_message).strip(), str(instruction).strip(), " ".join(command_args)) if part
    ).lower()
    if not combined:
        return False

    has_close_verb = any(verb in combined for verb in (
        "close", "quit", "exit", "shutdown", "shut down", "terminate",
    ))
    has_browser_object = any(noun in combined for noun in (
        "browser", "tab", "session", "window",
    ))
    return has_close_verb and has_browser_object


def _infer_url_from_text(text: str) -> str | None:
    raw = str(text or "").strip()
    if not raw:
        return None
    http_match = re.search(r"https?://\\S+", raw, flags=re.IGNORECASE)
    if http_match:
        return http_match.group(0).rstrip(".,)")
    bare_match = re.search(r"\\b([a-zA-Z0-9-]+\\.[a-zA-Z]{2,})(/\\S*)?\\b", raw)
    if bare_match:
        return f"https://{bare_match.group(0).rstrip('.,)')}"
    return None


def _is_open_only_instruction(instruction: str) -> bool:
    """True only for pure navigation requests (open/go-to/navigate-to) with no follow-up actions."""
    raw = str(instruction or "").strip()
    if not raw:
        return True

    lower = raw.lower()
    has_open_phrase = (
        lower.startswith("open ")
        or lower.startswith("go to ")
        or lower.startswith("navigate to ")
        or " go to " in f" {lower} "
    )
    if not has_open_phrase:
        return False

    # If the user asks for any additional action, this is not open-only.
    has_followup_action = bool(re.search(
        r"\b(and|then|after|click|tap|select|search|find|type|enter|fill|submit|"
        r"login|log in|sign in|scroll|extract|scrape|download|bookmark|vote|post|comment)\b",
        lower,
    ))
    return not has_followup_action


def _guess_image_media_type(raw: bytes) -> str:
    """Infer image media type from magic bytes."""
    if raw.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if raw.startswith(b"GIF87a") or raw.startswith(b"GIF89a"):
        return "image/gif"
    if raw.startswith(b"RIFF") and raw[8:12] == b"WEBP":
        return "image/webp"
    return "image/png"


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
    lowered = model.lower()
    if lowered == "claude":
        return None
    # Map short aliases to full model IDs
    if lowered == "claude-opus-4-5":
        return "claude-opus-4-5-20250514"
    if lowered == "claude-sonnet-4-5":
        return "claude-sonnet-4-5-20250929"
    return model


def generate_session_title(user_message: str) -> str:
    """Generate a brief (2-6 word) session title from the user's first message."""
    truncated = user_message.strip()[:500]
    if not truncated:
        return "Untitled"

    prompt = (
        "Generate a very brief title (2-6 words) summarizing this user request. "
        "Return ONLY the title text. No quotes, no ending punctuation.\n\n"
        f"Request: {truncated}"
    )

    # Try Gemini first (fastest/cheapest)
    gemini_key = (
        os.environ.get("GEMINI_API_KEY", "").strip()
        or os.environ.get("GOOGLE_API_KEY", "").strip()
    )
    if gemini_key:
        try:
            body = {
                "contents": [{"role": "user", "parts": [{"text": prompt}]}],
                "generationConfig": {"temperature": 0.3, "maxOutputTokens": 30},
            }
            data = _gemini_post(DEFAULT_GEMINI_MODEL, body, gemini_key)
            text = _extract_gemini_text(data).strip().strip('"\'').rstrip(".")
            if text:
                return text
        except Exception:
            pass

    # Try OpenAI fallback
    openai_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if openai_key:
        try:
            client = OpenAI(api_key=openai_key)
            resp = client.chat.completions.create(
                model="gpt-4.1-mini",
                messages=[{"role": "user", "content": prompt}],
                max_tokens=30,
            )
            text = (resp.choices[0].message.content or "").strip().strip('"\'').rstrip(".")
            if text:
                return text
        except Exception:
            pass

    # Fallback: truncate message
    clean = user_message.strip()
    if len(clean) > 40:
        clean = clean[:37] + "..."
    return clean or "Untitled"


def _resolve_gemini_model(model: str) -> str:
    lowered = model.lower()
    if lowered in {"gemini", "gemini-flash"}:
        return DEFAULT_GEMINI_MODEL
    # Resolve short alias to full model ID
    if lowered == "gemini-3-flash":
        return "gemini-3.0-flash"
    return model

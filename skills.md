# Iris Widget Skills Context

This file is shared context for `claude code`, `codex`, and any orchestrator agent that needs to create or route Iris widgets.

## 1) Canonical Widget Object

Use this shape as the source of truth for widget payloads:

```json
{
  "id": "optional-stable-id",
  "title": "Optional title",
  "kind": "html | markdown | text | image | chart",
  "width": 520,
  "height": 420,
  "css": "optional css string",
  "payload": {
    "html": "for kind=html",
    "markdown": "for kind=markdown",
    "text": "for kind=text",
    "imageUrl": "for kind=image",
    "chartConfig": {}
  }
}
```

Validation rules:
- `kind` must be one of: `html`, `markdown`, `text`, `image`, `chart`.
- Unknown/invalid widget objects are ignored.
- `payload` keys should match `kind`.

## 2) How Widgets Open In Iris

There are two supported paths:

1. Stream event path (`widget.open`):
- Backend/orchestrator emits an event like:
```json
{ "kind": "widget.open", "widget": { "...WidgetSpec..." } }
```
- Mac app normalizes and opens it immediately.

2. Inline text path (`iris-widget` fenced JSON):
- Agent final text can include fenced blocks:
```iris-widget
{ "...WidgetSpec..." }
```
- Mac app extracts blocks, opens widgets, and keeps any remaining text.

## 3) Agent-Specific Rules

### Iris agent (`agents/iris_agent.py`)
- Can use tool `push_widget(html, target, widget_id, width?, height?)`.
- Can use tool `run_bash(command, cwd?, timeout_seconds?, max_output_chars?)`.
- Can use tool `web_search(query, max_results?)`.
- Can use tool `read_screenshot(device)` and `read_transcript(limit?)`.
- Tool currently posts to iPad canvas API (`POST /api/v1/objects`).
- On success, stream includes `widget.open` with:
  - `kind: "html"`
  - `id: widget_id`
  - `payload.html`

### Claude Code + Codex adapters (`agents/claude_code.py`, `agents/codex_agent.py`)
- No widget tool integration in current adapters.
- To open a widget in Mac UI, return valid `iris-widget` fenced JSON in final text.
- If no widget block is returned, output is treated as plain assistant text.

### Orchestrator/backend agent
- Should emit supported stream events: `status`, `message.delta`, `message.final`, `tool.call`, `tool.result`, `widget.open`, `error`.
- For widget delivery, emit `widget.open` with a valid `WidgetSpec`.
- SSE (`data: {...}`) and NDJSON (`{...}` per line) are both supported.

## 4) iPad Widget Contract

iPad API endpoint:
- `POST /api/v1/objects`

Body:
- `html` (required)
- `x` (default `0`) offset from current viewport center
- `y` (default `0`) offset from current viewport center
- `width` (default `320`)
- `height` (default `220`)
- `animate` (default `true`)

Behavior:
- iPad injects design-system CSS into widget HTML automatically.
- Placement coordinates are viewport-relative on create.
- Listing/query returns canvas-center-relative coordinates.
- Widget internals are not touch-interactive on iPad (`WKWebView` interaction disabled); users can drag widget containers on canvas.

## 5) Mac Widget Contract

Mac opens widgets through Electron `open-widget` IPC using `WidgetSpec`.

Behavior:
- Supported kinds: `html`, `markdown`, `text`, `image`, `chart`.
- Defaults: `width=520`, `height=420`, min size `280x200`.
- Reusing an existing `id` focuses the existing widget window instead of creating a duplicate.
- `css` is appended to window styles and can theme the widget.

## 6) Authoring Guidance For Reliable Widgets

- Prefer `kind: "html"` unless another kind is clearly better.
- Keep widget output self-contained (inline HTML/CSS/JS).
- Include explicit `width` and `height` for predictable sizing.
- Use stable `id` values for widgets that should be updated/focused.
- Avoid large external dependencies for critical flows.
- Keep fallback text outside widget blocks minimal and useful.

## 6.1) Visual Quality Bar (iPad Widgets)

Default to a polished, premium UI direction similar to a modern glassy dashboard, not plain utility HTML.

Required style expectations:
- Use layered depth: gradient/atmospheric background + translucent cards (`backdrop-filter` when available) + soft inner/outer borders.
- Use clear visual hierarchy: strong headline, secondary metadata, subtle tertiary labels.
- Use purposeful spacing: 12/16/24 rhythm, generous padding, no cramped edges.
- Use rounded geometry: 16-24px card radii, consistent corner language.
- Use high-contrast typography with refined neutrals; avoid washed-out gray-on-gray text.
- Prefer componentized card layouts (hero panel + supporting metric cards) over one dense block of text.
- Include tasteful visual accents (status pills, progress bars, mini charts, avatars, icon chips) when relevant.
- Keep interactions lightweight and reliable (hover/tap states optional, no heavy framework dependencies).

Avoid:
- Bare white cards with default browser typography.
- Unstyled tables/lists as the primary presentation.
- Random color usage or mismatched spacing/radii.
- Generic "AI slop" layouts with no visual focal point.

Recommended implementation pattern:
- Define CSS tokens in `:root` (colors, radius, spacing, shadows).
- Compose reusable classes like `.panel`, `.metric`, `.badge`, `.muted`, `.kpi`.
- Start with semantic HTML, then layer visual treatment.

## 7) Copy/Paste Templates

Template: `iris-widget` block (for Claude Code/Codex text output)

```iris-widget
{
  "id": "task-summary",
  "title": "Task Summary",
  "kind": "html",
  "width": 700,
  "height": 520,
  "payload": {
    "html": "<div class='card'><h2>Summary</h2><p>Ready.</p></div>"
  }
}
```

Template: orchestrator stream event

```json
{
  "kind": "widget.open",
  "widget": {
    "id": "task-summary",
    "title": "Task Summary",
    "kind": "html",
    "width": 700,
    "height": 520,
    "payload": {
      "html": "<div class='card'><h2>Summary</h2><p>Ready.</p></div>"
    }
  }
}
```

Template: Iris tool call intent

```json
{
  "name": "push_widget",
  "arguments": {
    "target": "ipad",
    "widget_id": "task-summary",
    "width": 320,
    "height": 220,
    "html": "<div class='card'><h3>Summary</h3><p>Ready.</p></div>"
  }
}
```

## 8) Source Files (Implementation Truth)

- `agents/tools/widget.py`
- `agents/iris_agent.py`
- `agents/server.py`
- `mac/src/lib/widgetProtocol.ts`
- `mac/src/lib/agentProtocol.ts`
- `mac/src/lib/agentTransport.ts`
- `mac/electron/WidgetWindowManager.ts`
- `iPad/README.md`
- `iPad/iris-app/Services/AgentHTTPServer.swift`
- `iPad/iris-app/Views/CanvasObjectWebView.swift`

# Iris Agent Skills Reference

## Tools

The Iris agent has 4 tools: `draw`, `push_widget`, `read_screenshot`, and `read_widget`.

---

### draw

Draw a diagram onto the PencilKit canvas with animated cursor tracing. The AI cursor follows each stroke as it appears — as if drawing by hand. **This is the primary tool for all diagrams.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `svg` | string | **yes** | SVG string content (rendered from D2 or hand-crafted) |
| `scale` | number | no | Scale factor for SVG coordinates (default 1.0, use 1.5-2.0 for readable size) |
| `speed` | number | no | Animation speed multiplier (default 1.0) |
| `color` | string | no | Hex color for strokes (default `#1A1F28`) |
| `stroke_width` | number | no | PencilKit stroke width (default 3) |
| `x` | number | no | X position offset (default 0) |
| `y` | number | no | Y position offset (default 0) |
| `coordinate_space` | string | no | `"viewport_offset"` (default). Other spaces are accepted, but drawn images are clamped to stay inside the current viewport. |

**Workflow:** Write D2 source -> render with `d2` CLI -> send SVG to draw endpoint.

**Supported SVG elements:** path (all commands), rect, line, polyline, polygon, circle, ellipse. Text is skipped. Filled polygons (e.g. arrowheads) are rasterized as PencilKit strokes.

```json
{
  "svg": "<svg viewBox='0 0 300 200'>...</svg>",
  "scale": 2.0,
  "speed": 1.5,
  "color": "#1A1F28",
  "stroke_width": 3
}
```

Returns 202:
```json
{
  "status": "drawing",
  "stroke_count": 13,
  "estimated_duration_seconds": 5.1
}
```

---

### push_widget

Push an interactive HTML widget to a target device. Use for **interactive content only** (calculators, timers, documents with LaTeX) — NOT for diagrams.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `widget_id` | string | **yes** | Unique identifier (descriptive slug, e.g. `"formula-ref-1"`) |
| `target` | string | **yes** | `"mac"` (desktop overlay) or `"ipad"` (canvas widget) |
| `type` | string | no | `"html"` (default), `"document"`, `"animation"` |
| `source` | string | no | Content for `document` (Markdown+LaTeX) or `animation` (Manim) |
| `html` | string | no | Raw HTML for `html` type only (self-contained, inline CSS/JS) |
| `width` | number | no | Width in points (default 320) |
| `height` | number | no | Height in points (default 220) |
| `x` | number | no | X position in coordinate_space (default 0) |
| `y` | number | no | Y position in coordinate_space (default 0) |
| `coordinate_space` | string | no | `"viewport_offset"` (default), `"canvas_absolute"`, `"document_axis"` |
| `anchor` | string | no | `"top_left"` (default) or `"center"` |

#### Widget Types

**`document`** — Markdown + LaTeX rendering
- Set `source` to Markdown. `$...$` for inline math, `$$...$$` for display math.

**`animation`** — Manim (ManimCE) scene
- Set `source` to a Python class extending `Scene` with `construct()`.
- Only use when motion genuinely aids understanding.

**`html`** — Raw interactive HTML (default)
- Set `html` to self-contained HTML (inline CSS/JS only).
- Use for: timers, calculators, games, anything needing JS interactivity.

---

### read_screenshot

Analyze the latest device screenshot for spatial cues and placement guidance.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | string | no | Filter by device (`"ipad"`, `"mac"`) |
| `session_id` | string | no | Filter by session |
| `question` | string | no | Spatial question to answer about the screenshot |

---

### read_widget

Load a pre-built widget from the library by name.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **yes** | Widget slug (e.g. `"calculator"`, `"graph"`, `"timer"`) |

Available: `calculator` (320x520), `graph` (420x380), `timer` (320x340).

---

## When to Use What

| Content | Tool | Why |
|---------|------|-----|
| Flowchart, architecture, tree, graph | **draw** | Drawn as PencilKit strokes with cursor animation |
| Any D2 diagram | **draw** | D2 -> SVG -> draw |
| Any SVG content | **draw** | Parsed and drawn as strokes |
| Calculator, timer, interactive tool | **push_widget** (html) | Needs JS interactivity |
| Math equations, explanations | **push_widget** (document) | Needs KaTeX rendering |
| Step-by-step animation | **push_widget** (animation) | Needs Manim video playback |

## Device Targeting

| Scenario | Target |
|----------|--------|
| Diagram on canvas | **draw** (always iPad) |
| Widget aiding canvas work | `push_widget` target `"ipad"` |
| Self-contained tool (timer, calc) | `push_widget` target `"mac"` |
| Conversational request at Mac | `push_widget` target `"mac"` |

## Coordinate Spaces

- **`viewport_offset`** — (0,0) = center of user's current view
- **`document_axis`** — Stable canvas geometry, persistent across zoom/pan
- **`canvas_absolute`** — Raw canvas coordinates (rarely needed)

## Style Reference (Apple iOS/macOS widgets)

- Background: `#1c1c1e` (dark). No borders.
- Corner radius: `20px`. Padding: 16-20px.
- Font: `-apple-system, SF Pro`. Labels 11-12px uppercase. Hero 34-48px bold. Body 13-14px muted.
- Accent: one per widget — red `#ff3b30`, orange `#ff9500`, green `#34c759`, blue `#007aff`, purple `#af52de`.
- No gradients, shadows, or hover effects.

## Key Rules

1. **Diagrams = draw, always** — never place diagrams as WebView widgets.
2. **Widgets = interactive HTML only** — calculators, timers, documents, not diagrams.
3. **Prefer library widgets** — `read_widget` -> adapt -> `push_widget`.
4. **Always specify coordinates** — `x`, `y`, `coordinate_space` for every placement.
5. **Drawn images must stay in view** — image placement is constrained to the active viewport.
6. **Widget must contain the answer** — no restating the problem.

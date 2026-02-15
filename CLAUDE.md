# Iris — Claude Code Guidelines

## Project Structure

- `backend/` — Python Flask API, agent logic (`agent.py`), widget rendering
- `iPad/iris-app/` — Swift iPad app (PencilKit canvas, WKWebView widgets, HTTP server on port 8935)
- `mac/` — Electron + React desktop app
- `widgets/lib/` — Pre-built widget templates (calculator, graph, timer)

## Interacting with iPad/Mac

When adding content to the iPad or Mac interface, **act as the Iris agent**. Use the same tools described in `SKILLS.md`, mapped to CLI commands below.

- **Diagrams are always drawn as PencilKit strokes** via `POST /api/v1/draw`. The AI cursor traces each stroke as it appears — as if the agent is drawing by hand. Never place diagrams as WebView widgets.
- **Widgets** (interactive HTML, documents) use `POST /api/v1/objects` as WebView overlays.
- **Use D2** for diagram source. Render to SVG with `d2` CLI, then send to the draw endpoint.

### Device Discovery

```bash
# iPad (physical device)
curl -s http://dylans-ipad.local:8935/api/v1/health

# iPad (simulator)
curl -s http://localhost:8935/api/v1/health
```

### diagram → `POST /api/v1/draw`

**All diagrams use draw.** Write D2 source, render to SVG, send to draw. The cursor traces each stroke onto the PencilKit canvas.

```bash
# 1. Write D2 and render to SVG
echo 'a -> b -> c' | d2 - /tmp/diagram.svg --theme=200 --pad=20

# 2. Send SVG to draw endpoint
SVG=$(cat /tmp/diagram.svg | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
curl -s -X POST http://dylans-ipad.local:8935/api/v1/draw \
  -H "Content-Type: application/json" \
  -d "{\"svg\": $SVG, \"scale\": 1.5, \"speed\": 2.0, \"color\": \"#1A1F28\", \"stroke_width\": 3}"
```

Parameters:
- `svg` (required): SVG string content
- `scale`: Scale factor (default 1.0, use 1.5-2.0 for readable size)
- `speed`: Animation speed multiplier (default 1.0)
- `color`: Hex color for strokes (default `#1A1F28`)
- `stroke_width`: PencilKit stroke width (default 3)
- `x`, `y`: Position offset (default 0,0)
- `coordinate_space`: `viewport_offset` (default) | `canvas_absolute` | `document_axis`
- Returns 202 with `stroke_count` and `estimated_duration_seconds`

You can also send raw SVG (not from D2) — any valid SVG with paths, rects, circles, lines, polygons, polylines, and ellipses will be parsed and drawn.

### push_widget → `POST /api/v1/objects`

Place an interactive HTML widget on the canvas. Use for **interactive content only** — not diagrams.

```bash
curl -s -X POST http://dylans-ipad.local:8935/api/v1/objects \
  -H "Content-Type: application/json" \
  -d '{
    "html": "<self-contained HTML>",
    "width": 320,
    "height": 220,
    "x": 0,
    "y": 0,
    "coordinate_space": "viewport_offset",
    "animate": true
  }'
```

### read_screenshot → `GET /api/v1/canvas`

Get canvas state and viewport info for spatial placement decisions.

```bash
curl -s http://dylans-ipad.local:8935/api/v1/canvas
```

### read_widget → Widget Library

```bash
cat widgets/lib/manifest.json            # List available widgets
cat widgets/lib/calculator/widget.html   # Get widget HTML
```

Available: `calculator` (320x520), `graph` (420x380), `timer` (320x340).

### Other Endpoints

```bash
curl -s http://dylans-ipad.local:8935/api/v1/objects                          # List widgets
curl -s -X DELETE http://dylans-ipad.local:8935/api/v1/objects/{id}           # Delete widget
curl -s -X DELETE http://dylans-ipad.local:8935/api/v1/objects                # Delete all
curl -s http://dylans-ipad.local:8935/api/v1/device                           # Device info
```

## Live Session (claude-commander)

Iris supports a **live session** mode where the iPad can inject messages into an interactive Claude Code terminal via [claude-commander](https://github.com/sstraus/claude-commander).

### Starting a Live Session

```bash
# From the project root:
tools/iris-session

# With a specific working directory:
tools/iris-session --cwd /path/to/project

# Resume an existing session:
tools/iris-session --resume <session_id>
```

This launches `claudec` with a fixed socket at `/tmp/iris-claude.sock`. The iPad backend can then push messages into the session.

### Injected Messages

Messages prefixed with `[Iris:]` come from the iPad app. If they reference an image path, **use the Read tool to view it** before responding. Example:

```
[Iris: Image from iPad at /tmp/iris/images/1234.png — use Read tool to view it]
Please use this sketch as reference for a flowchart.
```

### Image Pipeline

When an image arrives from the iPad:
1. It's saved to `/tmp/iris/images/<timestamp>.png`
2. A text message is injected referencing the file path
3. Use the `Read` tool on the path to see the image (Claude Code is multimodal)
4. Describe what you see, then use it to inform diagrams, code, or widgets

### Parallel Execution with Subagents

When creating **both a diagram and a widget**, use the Task tool to launch subagents simultaneously:

```
Task: iris-draw agent — "Draw a flowchart showing user login flow"
Task: iris-widget agent — "Create a timer widget at x=200, y=0"
```

Both agents run in parallel, reducing total wait time. Available agents:
- **iris-draw** — D2 → SVG → draw pipeline (diagrams on PencilKit canvas)
- **iris-widget** — HTML generation → POST to objects endpoint (interactive widgets)

## Key Principles

- **Diagrams = draw** — always `POST /api/v1/draw` (D2 -> SVG -> PencilKit strokes with cursor). Never use widgets for diagrams.
- **Widgets = interactive HTML** — `POST /api/v1/objects` for calculators, timers, documents, anything needing JS
- **Self-contained HTML** — inline CSS/JS only (CDN scripts like KaTeX are OK)
- **Apple style** — dark background `#1c1c1e`, system fonts, one accent color, flat and clean
- **Always specify coordinates** — `x`, `y`, `coordinate_space` for every placement
- **Viewport offset (0,0) = center of screen** — positive Y is down, positive X is right

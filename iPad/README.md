# Iris Canvas — Agent HTTP API

Iris exposes a local HTTP server (running on the iPad itself) that lets AI agents place rich HTML widgets on the infinite canvas. Widgets are rendered as `WKWebView` instances with a built-in design system for visual consistency. An animated cursor choreographs each placement. Users can drag widgets to reposition them.

## Architecture

```
┌──────────────┐  1. Bonjour (_iris-canvas._tcp)  ┌────────────────┐
│  Mac App     │  ◄── auto-discovered ───────────  │  iPad App      │
│  (Electron)  │  2. POST /api/v1/link ─────────▶  │  (NWListener)  │
│              │  3. POST /api/v1/objects ───────▶  │                │
└──────────────┘                                   └────────────────┘
```

The HTTP server runs **inside the iPad app**. The iPad advertises itself via Bonjour — Mac discovers it automatically on the same Wi-Fi. No manual IP entry needed.

- **Simulator**: `http://localhost:8935` (shares host network)
- **Real iPad**: `http://<ipad-ip>:8935` (same Wi-Fi network)

## Quick Start

```bash
# Health check
curl http://localhost:8935/api/v1/health

# Place a widget where the user is looking
curl -X POST http://localhost:8935/api/v1/objects \
  -H 'Content-Type: application/json' \
  -d '{"html": "<div class=\"card\"><h2>Hello</h2><p>From an agent.</p></div>"}'

# Place instantly (no cursor animation), offset right
curl -X POST http://localhost:8935/api/v1/objects \
  -H 'Content-Type: application/json' \
  -d '{"html": "<h1>Fast</h1>", "x": 200, "y": 0, "animate": false}'
```

## Coordinate System

**Placement (`POST`) uses viewport-relative coordinates** — offsets from where the user is currently looking:

| Value | Meaning |
|-------|---------|
| `x: 0, y: 0` | Center of the user's current view |
| `x: 200, y: 0` | 200pt right of where they're looking |
| `x: -100, y: 150` | 100pt left, 150pt below their view center |

This means agents don't need to know or care about absolute canvas position. Widgets always appear in view.

**Querying (`GET`) returns canvas-center-relative coordinates** — stable offsets from the fixed canvas center (50000, 50000). These don't change when the user scrolls.

Positive x = right, positive y = down (UIKit convention).

## Widget Interaction

- **Finger drag**: Repositions the widget on the canvas (lift + drop animation)
- **Pencil**: Draws over/around widgets (PencilKit layer)
- **Pinch zoom**: Widgets scroll and zoom with the canvas

## API Reference

### `GET /api/v1/health`

**Response** `200`
```json
{ "status": "ok", "service": "iris-canvas", "version": "1.0" }
```

---

### `GET /api/v1/canvas`

Canvas and viewport metadata.

**Response** `200`
```json
{
  "canvas_size": 100000,
  "canvas_center": { "x": 50000, "y": 50000 },
  "viewport_center": { "x": 50120, "y": 49870 },
  "coordinate_info": "POST x/y are offsets from the user's current viewport center. GET x/y are offsets from canvas center."
}
```

---

### `GET /api/v1/design-system.css`

Returns the full CSS design system stylesheet. Useful for previewing widget HTML locally.

**Response** `200` `text/css`

---

### `POST /api/v1/objects`

Place a new HTML widget on the canvas.

**Request body**
```json
{
  "html": "<div class='card'><h2>Title</h2><p>Body</p></div>",
  "x": 0,
  "y": 0,
  "width": 320,
  "height": 220,
  "animate": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `html` | string | **required** | HTML content. Design system CSS is auto-injected. |
| `x` | number | `0` | Horizontal offset from viewport center (pt) |
| `y` | number | `0` | Vertical offset from viewport center (pt) |
| `width` | number | `320` | Widget width (pt) |
| `height` | number | `220` | Widget height (pt) |
| `animate` | bool | `true` | Cursor glides to position and clicks (~1.4s). `false` = instant. |

**Response** `201`
```json
{
  "id": "A1B2C3D4-...",
  "x": 0, "y": 0,
  "width": 320, "height": 220,
  "viewport_center": { "x": 50120, "y": 49870 },
  "canvas_position": { "x": 50120, "y": 49870 }
}
```

---

### `GET /api/v1/objects`

List all widgets. Positions are canvas-center-relative (stable).

**Response** `200`
```json
{
  "count": 2,
  "objects": [
    { "id": "...", "x": 120, "y": -130, "width": 320, "height": 220 },
    { "id": "...", "x": -200, "y": 50, "width": 280, "height": 160 }
  ]
}
```

---

### `GET /api/v1/objects/:id`

Get a widget's details including its HTML.

**Response** `200`
```json
{
  "id": "...", "x": 120, "y": -130,
  "width": 320, "height": 220,
  "html": "<div class='card'>...</div>"
}
```

---

### `DELETE /api/v1/objects/:id`

Remove a widget (animated fade-out).

**Response** `200` `{ "deleted": "A1B2C3D4-..." }`

---

### `DELETE /api/v1/objects`

Remove all widgets.

**Response** `200` `{ "deleted_count": 3 }`

---

### `GET /api/v1/device`

This iPad's device info.

**Response** `200`
```json
{
  "id": "F1AFF0C0-...",
  "name": "iPad Pro 13-inch (M4)",
  "model": "iPad",
  "system": "iPadOS 18.2",
  "service": "iris-canvas",
  "port": 8935
}
```

---

### `POST /api/v1/link`

Register a device (Mac, agent host, etc.) so the iPad knows about it. The iPad responds with its own device info — both sides now know each other.

**Request body**
```json
{
  "id": "mac-abc123",
  "name": "Dylan's MacBook Pro",
  "platform": "macOS"
}
```

**Response** `200`
```json
{
  "linked": true,
  "device": { "id": "F1AFF0C0-...", "name": "iPad Pro 13-inch (M4)", "model": "iPad", "system": "iPadOS 18.2", "port": 8935 }
}
```

---

### `GET /api/v1/link`

List all linked devices.

**Response** `200`
```json
{
  "count": 1,
  "devices": [
    { "id": "mac-abc123", "name": "Dylan's MacBook Pro", "platform": "macOS", "linked_at": "2025-01-15T..." }
  ]
}
```

---

### `DELETE /api/v1/link/:id`

Unlink a device.

**Response** `200` `{ "unlinked": "mac-abc123" }`

## Auto-Discovery (Bonjour)

The iPad automatically advertises itself on the local network via Bonjour as `_iris-canvas._tcp`. Any device on the same Wi-Fi can discover it — no manual IP entry needed.

```
┌──────────────┐   Bonjour (_iris-canvas._tcp)   ┌────────────────┐
│  Mac App     │  ◄── mDNS discovery ──────────  │  iPad App      │
│  (Electron)  │  ── POST /api/v1/link ────────▶  │  (NWListener)  │
│              │  ◀── { linked: true } ─────────  │                │
└──────────────┘                                  └────────────────┘
```

The Mac Electron app uses `bonjour-service` to browse for `_iris-canvas._tcp`, probes `/api/v1/device`, and auto-registers via `/api/v1/link`. Both devices know about each other within seconds of being on the same network.

**Browse manually (macOS terminal):**
```bash
dns-sd -B _iris-canvas._tcp
```

## Design System CSS

All widgets get the design system stylesheet injected automatically.

### Pre-styled Elements

`<h1>`–`<h4>`, `<p>`, `<code>`, `<pre>`, `<table>`, `<ul>`, `<ol>`, `<a>`, `<img>` are all styled with SF Pro fonts, proper spacing, and consistent colors.

### Utility Classes

| Class | Description |
|-------|-------------|
| `.card` | Rounded container with border and padding |
| `.badge` | Small pill label (accent blue) |
| `.badge.success` | Green badge |
| `.badge.warning` | Amber badge |
| `.badge.error` | Red badge |

### CSS Variables

```css
--iris-bg, --iris-text, --iris-text-secondary
--iris-accent, --iris-accent-light, --iris-border, --iris-surface
--iris-success, --iris-warning, --iris-error
--iris-font, --iris-font-mono
--iris-radius-sm, --iris-radius-md, --iris-radius-lg
--iris-space-xs, --iris-space-sm, --iris-space-md, --iris-space-lg, --iris-space-xl
```

## Examples

### Dashboard layout

```bash
# Three cards in a row
for i in 0 1 2; do
  curl -s -X POST http://localhost:8935/api/v1/objects \
    -H 'Content-Type: application/json' \
    -d "{\"html\": \"<div class='card'><h3>Card $i</h3><p>Content</p></div>\", \"x\": $((i * 300 - 300)), \"y\": 0, \"animate\": false}"
done
```

### Status card with table

```bash
curl -X POST http://localhost:8935/api/v1/objects \
  -H 'Content-Type: application/json' \
  -d '{
    "html": "<div class=\"card\"><h3>Status</h3><span class=\"badge success\">Online</span><table><tr><th>Metric</th><th>Value</th></tr><tr><td>CPU</td><td>23%</td></tr></table></div>",
    "width": 280, "height": 220
  }'
```

### Clear everything

```bash
curl -X DELETE http://localhost:8935/api/v1/objects
```

## Error Handling

All errors return JSON: `{ "error": "description" }`

| Status | Meaning |
|--------|---------|
| `400` | Bad request — missing fields, invalid UUID |
| `404` | Object not found, or unknown endpoint |
| `503` | Canvas not ready — no document is open yet |

## Testing

```bash
# Launch on simulator with auto-open
xcrun simctl launch booted com.dylan.iris -autoOpenFirst

# Verify
curl http://localhost:8935/api/v1/health
```

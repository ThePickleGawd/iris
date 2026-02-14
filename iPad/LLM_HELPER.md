# iPad LLM Helper

This file documents the iPad runtime APIs that an LLM agent can call to inspect canvas state, place widgets, and drive interaction.

## Base URL
- iPad local API: `http://<ipad-ip>:8935/api/v1`
- Health check: `GET /health`

## Coordinate System (Important)
- Canonical axis: `document_axis`
- `document_axis (0,0)` is the canvas center.
- `+x` moves right.
- `+y` moves down.
- Viewport changes with pan/zoom, but `document_axis` is stable.

You can query current viewport bounds via:
- `GET /canvas`

The response includes:
- `coordinate_info.supported_spaces`
- `coordinate_info.viewport_bounds_document_axis.top_left`
- `coordinate_info.viewport_bounds_document_axis.top_right`
- `coordinate_info.viewport_bounds_document_axis.bottom_left`
- `coordinate_info.viewport_bounds_document_axis.bottom_right`

## Recommended Placement Flow
1. Call `GET /canvas`.
2. Decide placement in `document_axis`.
3. Call `POST /objects` with `coordinate_space: "document_axis"`.
4. Verify with `GET /objects`.

## Endpoints

### 1. Health
- Method: `GET /health`
- Purpose: check service availability.

### 2. Canvas Info
- Method: `GET /canvas`
- Purpose: get canvas/viewport coordinate context.

### 3. Create Widget Object
- Method: `POST /objects`
- Required:
  - `html` (string): rendered content.
- Optional:
  - `coordinate_space` (string): one of `viewport_offset`, `canvas_absolute`, `document_axis`. Default `viewport_offset`.
  - `x` (number)
  - `y` (number)
  - `width` (number, default `320`)
  - `height` (number, default `220`)
  - `animate` (bool, default `true`)

Example (`document_axis`):
```bash
curl -X POST http://<ipad-ip>:8935/api/v1/objects \
  -H 'Content-Type: application/json' \
  -d '{
    "html":"<div class=\"card\"><h3>Status</h3><p>Hello</p></div>",
    "coordinate_space":"document_axis",
    "x":120,
    "y":-80,
    "width":340,
    "height":220,
    "animate":true
  }'
```

### 4. List Widgets
- Method: `GET /objects`
- Returns each object with:
  - `document_axis_x`, `document_axis_y`
  - `canvas_x`, `canvas_y`
  - `width`, `height`

### 5. Get Widget by ID
- Method: `GET /objects/:id`

### 6. Delete Widget
- Method: `DELETE /objects/:id`

### 7. Delete All Widgets
- Method: `DELETE /objects`

### 8. Suggestion Chips (Pending add/reject flow)
- Create suggestion: `POST /suggestions`
- List suggestions: `GET /suggestions`
- Approve suggestion: `POST /suggestions/:id/approve`
- Reject suggestion: `POST /suggestions/:id/reject`

`POST /suggestions` body:
- Required: `html`
- Optional: `title`, `summary`, `x`, `y`, `width`, `height`, `animate`
- Note: current suggestion coordinates are interpreted as viewport-relative offsets.

### 9. Cursor Control
- Method: `POST /cursor`
- Body:
  - `action`: `appear | move | click | disappear`
  - `x`, `y`: viewport-relative offsets

Example:
```bash
curl -X POST http://<ipad-ip>:8935/api/v1/cursor \
  -H 'Content-Type: application/json' \
  -d '{"action":"move","x":80,"y":40}'
```

### 10. Device/Link APIs
- Device info: `GET /device`
- Link remote: `POST /link`
- List links: `GET /link`
- Unlink: `DELETE /link/:id`

## Corner Placement Recipe (Current Viewport)
1. `GET /canvas`
2. Read `coordinate_info.viewport_bounds_document_axis`:
  - `top_left`
  - `top_right`
  - `bottom_left`
  - `bottom_right`
3. Place objects with `coordinate_space: "document_axis"`.

For right/bottom corners, subtract widget width/height to keep full widget visible.

## Off-Screen Placement
To place off-screen intentionally, send large/small `document_axis` values.

Example:
```bash
curl -X POST http://<ipad-ip>:8935/api/v1/objects \
  -H 'Content-Type: application/json' \
  -d '{"html":"<div>Off-screen</div>","coordinate_space":"document_axis","x":9000,"y":9000}'
```

## Screenshot Context for LLMs
When iPad uploads screenshots to backend, it includes coordinate metadata in screenshot `notes`:
- viewport corner coordinates in `document_axis`
- serialized coordinate snapshot JSON

If your agent uses backend screenshot APIs (`/api/screenshots`), read `notes` and use those coordinates for precise placement decisions.

## LLM Practical Guidance
- Default to no-op unless explicit reason to add a widget.
- Prefer `document_axis` for stable placement.
- Before creating a widget, query `GET /objects` to avoid duplicates.
- Keep widget HTML self-contained (inline CSS/JS).
- Use moderate default size around `320x220` unless content needs more space.

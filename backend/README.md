# iris backend

Minimal Flask backend to centralize multimodal inputs on a Mac:

- on-device speech transcript ingestion (text)
- screenshot/diagram uploads

## Run

```bash
uv venv
source .venv/bin/activate
uv sync
uv run python app.py
```

Service starts at `http://localhost:5000`.

Optional env:

- `CORS_ALLOW_ORIGIN` (default `*`), e.g. `http://localhost:5173` for a specific frontend origin.

## Endpoints

### Health

- `GET /health`

### Transcript ingestion

1. Ingest transcript text:

```bash
curl -X POST http://localhost:5000/api/transcripts \
  -H "Content-Type: application/json" \
  -d '{
    "text":"Draft architecture uses event routing per device.",
    "device_id":"iPhone",
    "source":"speech",
    "captured_at":"2026-02-14T20:30:00Z"
  }'
```

2. Fetch transcript:

- `GET /api/transcripts/<transcript_id>`

3. Update transcript text:

```bash
curl -X PUT http://localhost:5000/api/transcripts/<transcript_id> \
  -H "Content-Type: application/json" \
  -d '{
    "text":"Updated transcript after local correction.",
    "captured_at":"2026-02-14T20:31:00Z"
  }'
```

4. Delete transcript:

```bash
curl -X DELETE http://localhost:5000/api/transcripts/<transcript_id>
```

5. List transcripts for sync (supports `cursor`, `since`, `device_id`, `limit`):

```bash
curl "http://localhost:5000/api/transcripts?since=2026-02-14T20:00:00Z&limit=100"
```

Preferred paging (stable for same-timestamp events):

```bash
curl "http://localhost:5000/api/transcripts?cursor=2026-02-14T20:00:00Z|<last_id>&limit=100"
```

### Screenshot ingestion

1. Upload screenshot/diagram:

```bash
curl -X POST http://localhost:5000/api/screenshots \
  -F "screenshot=@diagram.png" \
  -F "device_id=ipad-pro-1" \
  -F "captured_at=2026-02-14T20:30:00Z" \
  -F "source=diagram" \
  -F "notes=Architecture draft"
```

`device_id` is a free-form string and `captured_at` is optional ISO-8601. If `captured_at` is omitted, server receive time is used.

2. Get metadata:

- `GET /api/screenshots/<screenshot_id>`

Screenshot metadata now includes `file_url` for cross-device fetches (instead of relying on local `file_path`).

3. Get raw file:

- `GET /api/screenshots/<screenshot_id>/file`

4. Delete screenshot:

```bash
curl -X DELETE http://localhost:5000/api/screenshots/<screenshot_id>
```

5. List screenshot metadata for sync (supports `cursor`, `since`, `device_id`, `limit`):

```bash
curl "http://localhost:5000/api/screenshots?since=2026-02-14T20:00:00Z&limit=100"
```

### Unified event feed

Poll both modalities from one endpoint:

```bash
curl "http://localhost:5000/api/events?since=2026-02-14T20:00:00Z&limit=100"
```

Optional query params:
- `cursor`: stable cursor in format `<iso-ts>|<id>` (recommended)
- `since`: timestamp-only fallback cursor (exclusive)
- `limit`: max rows (`<= 200`)
- `device_id`: filter to one device
- `event_type`: `transcript` or `screenshot`

Responses from list/feed endpoints include `next_cursor` (recommended for next poll) and `next_since` (legacy fallback).
Screenshot items in list/feed responses include `file_url`.

### Device Command Bus

Peripherals can consume derived commands without reading raw screenshots/transcripts.

1. Create command (usually from agent/mac orchestrator):

```bash
curl -X POST http://localhost:5000/api/device-commands \
  -H "Content-Type: application/json" \
  -d '{
    "target_device_id":"iPad Diagram",
    "source_device_id":"iris-mac",
    "command_type":"diagram.edit",
    "payload":{"operation":"rename_node","node_id":"n1","label":"Auth Service"}
  }'
```

2. Peripheral polls commands:

```bash
curl "http://localhost:5000/api/device-commands?target_device_id=iPad%20Diagram&limit=50"
```

Optional query params:
- `statuses`: comma-separated statuses (default: `queued,in_progress`)
- `cursor`: `<iso-ts>|<id>` for stable paging
- `since`: timestamp fallback cursor

3. Peripheral ack/updates status:

```bash
curl -X POST http://localhost:5000/api/device-commands/<command_id>/ack \
  -H "Content-Type: application/json" \
  -d '{
    "status":"completed",
    "result":{"ok":true}
  }'
```

4. Fetch one command (for status/result):

- `GET /api/device-commands/<command_id>`

## Demo On LAN (iPad/Widget)

1. Start Flask (already binds to all interfaces in `app.py`): `uv run python app.py`
2. Find Mac LAN IP (example): `ipconfig getifaddr en0`
3. Use `http://<mac-lan-ip>:5000` from iPad/widget clients (not `localhost`)
4. If needed, set CORS for your client origin:
   - `CORS_ALLOW_ORIGIN=http://<client-origin> uv run python app.py`
5. Allow incoming connections for Python/Terminal in macOS Firewall when prompted

## Basic safety guards

- Request size cap: `15 MB` (`413` if exceeded)
- Screenshot MIME validation: must be `image/*`
- Transcript text length cap: `20,000` chars
- In-memory rate limits (per IP + route, per minute):
  - default API traffic: `120`
  - screenshot uploads: `30`
- CORS for `/api/*`, including `OPTIONS` preflight responses

## Storage layout

- `data/iris.db`: metadata (transcripts and screenshots)
- `data/screenshots/<device-id>/`: screenshot blobs grouped by sanitized device ID (fallback: `unknown-device`)

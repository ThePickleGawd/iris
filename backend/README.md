# iris backend

Minimal Flask backend to centralize multimodal inputs on a Mac:

- streamed speech audio chunks
- finalized audio session metadata + transcript text
- screenshot/diagram uploads

## Run

```bash
uv venv
source .venv/bin/activate
uv sync
uv run python app.py
```

Service starts at `http://localhost:5000`.

## Endpoints

### Health

- `GET /health`

### Audio ingestion

1. Create session:

```bash
curl -X POST http://localhost:5000/api/audio/sessions \
  -H "Content-Type: application/json" \
  -d '{"device_id":"ipad-pro-1","mime_type":"audio/webm"}'
```

2. Upload chunks (index required):

```bash
curl -X POST "http://localhost:5000/api/audio/sessions/<session_id>/chunks?index=0" \
  --data-binary "@chunk0.webm"
```

Or multipart:

```bash
curl -X POST "http://localhost:5000/api/audio/sessions/<session_id>/chunks?index=1" \
  -F "chunk=@chunk1.webm"
```

3. Finalize (optionally include transcript text):

```bash
curl -X POST http://localhost:5000/api/audio/sessions/<session_id>/finalize \
  -H "Content-Type: application/json" \
  -d '{"transcript":"Initial transcript text"}'
```

When a session is finalized, uploaded chunk files for that session are automatically deleted.

4. Update transcript later:

```bash
curl -X PUT http://localhost:5000/api/audio/sessions/<session_id>/transcript \
  -H "Content-Type: application/json" \
  -d '{"text":"Refined transcript after speech-to-text pipeline"}'
```

5. Fetch session:

- `GET /api/audio/sessions/<session_id>`

6. Delete session (+ finalized audio file):

```bash
curl -X DELETE http://localhost:5000/api/audio/sessions/<session_id>
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

3. Get raw file:

- `GET /api/screenshots/<screenshot_id>/file`

4. Delete screenshot:

```bash
curl -X DELETE http://localhost:5000/api/screenshots/<screenshot_id>
```

## Storage layout

- `data/iris.db`: metadata (sessions, chunks, transcripts, screenshots)
- `data/audio_chunks/`: chunked audio uploads
- `data/audio_final/`: concatenated finalized audio files
- `data/screenshots/<device-id>/`: screenshot blobs grouped by sanitized device ID (fallback: `unknown-device`)

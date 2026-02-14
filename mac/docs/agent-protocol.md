# Iris Agent Wire Protocol (v1.0)

This document defines the initial app <-> backend contract used by Iris when `Transport Mode = Backend Agent`.

## Request

`POST {BACKEND_BASE_URL}{BACKEND_STREAM_PATH}`

Headers:
- `Content-Type: application/json`
- `Accept: text/event-stream, application/x-ndjson, application/json`
- Optional: `Authorization: Bearer <token>`

Body (`agent.request`):

```json
{
  "protocol_version": "1.0",
  "kind": "agent.request",
  "request_id": "1739590000-abc123",
  "timestamp": "2026-02-14T12:00:00.000Z",
  "workspace_id": "default-workspace",
  "session_id": "default-session",
  "device": {
    "id": "device-xxxx",
    "name": "iris-mac",
    "platform": "MacIntel",
    "app_version": "0.1.0"
  },
  "input": {
    "type": "text",
    "text": "User message"
  },
  "context": {
    "recent_messages": [
      { "role": "user", "text": "..." },
      { "role": "assistant", "text": "..." }
    ]
  }
}
```

## Streamed Response Events

Backend can return either:
- SSE (`data: {...}` per event), or
- NDJSON (`{...}\n` per event)

Supported event kinds:

### `status`
```json
{ "kind": "status", "state": "planning", "detail": "optional" }
```

### `message.delta`
```json
{ "kind": "message.delta", "delta": "partial text" }
```

### `message.final`
```json
{ "kind": "message.final", "text": "final assistant text" }
```

### `tool.call`
```json
{ "kind": "tool.call", "name": "search", "input": { "q": "..." } }
```

### `tool.result`
```json
{ "kind": "tool.result", "name": "search", "output": { "items": [] } }
```

### `error`
```json
{ "kind": "error", "message": "error details" }
```

## Compatibility Shortcuts

Iris also accepts minimal events for compatibility:
- `{ "chunk": "..." }` -> treated as `message.delta`
- `{ "text": "..." }` -> treated as `message.final`
- `{ "error": "..." }` -> treated as `error`

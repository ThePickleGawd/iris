"""Iris backend — sessions, messages, screenshots, agent, devices."""
from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from flask import Flask, jsonify, request, send_file
from werkzeug.utils import secure_filename

import agent as agent_module

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
STORE_DIR = DATA_DIR / "store"
SCREENSHOTS_DIR = DATA_DIR / "screenshots"

for d in [STORE_DIR / "sessions", STORE_DIR / "messages", SCREENSHOTS_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Device registry (in-memory)
# ---------------------------------------------------------------------------
device_registry: dict[str, dict] = {}

# ---------------------------------------------------------------------------
# JSON file storage helpers
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _entity_path(entity: str, item_id: str) -> Path:
    return STORE_DIR / entity / f"{item_id}.json"


def _read(entity: str, item_id: str) -> dict | None:
    try:
        data = json.loads(_entity_path(entity, item_id).read_text())
        return data if isinstance(data, dict) else None
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _save(entity: str, row: dict) -> None:
    path = _entity_path(entity, row["id"])
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
    tmp.replace(path)


def _list(entity: str) -> list[dict]:
    rows = []
    entity_dir = STORE_DIR / entity
    if not entity_dir.exists():
        return rows
    for p in entity_dir.glob("*.json"):
        try:
            data = json.loads(p.read_text())
            if isinstance(data, dict):
                rows.append(data)
        except (json.JSONDecodeError, OSError):
            continue
    return rows


def _delete(entity: str, item_id: str) -> bool:
    try:
        _entity_path(entity, item_id).unlink()
        return True
    except FileNotFoundError:
        return False


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 15 * 1024 * 1024


@app.after_request
def _cors(response: Any) -> Any:
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response


@app.before_request
def _options() -> Any:
    if request.method == "OPTIONS":
        return "", 204
    return None


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> Any:
    return jsonify({"status": "ok", "devices": len(device_registry)})


# ---------------------------------------------------------------------------
# Sessions (served at /api/sessions and /sessions for client compat)
# ---------------------------------------------------------------------------

@app.post("/api/sessions")
@app.post("/sessions")
def create_session() -> Any:
    body = request.get_json(silent=True) or {}
    session_id = (body.get("id") or "").strip() or str(uuid.uuid4())
    model = (body.get("model") or body.get("agent") or "gpt-5.2").strip()
    name = (body.get("name") or "Untitled").strip()

    existing = _read("sessions", session_id)
    if existing:
        existing["updated_at"] = _now()
        if body.get("name"):
            existing["name"] = name
        if body.get("model") or body.get("agent"):
            existing["model"] = model
        _save("sessions", existing)
        return jsonify(existing), 201

    ts = _now()
    row = {
        "id": session_id,
        "created_at": ts,
        "updated_at": ts,
        "name": name,
        "model": model,
        "status": "active",
        "last_message_at": None,
    }
    _save("sessions", row)
    return jsonify(row), 201


@app.get("/api/sessions")
@app.get("/sessions")
def list_sessions() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = _list("sessions")
    rows.sort(key=lambda r: r.get("updated_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.get("/api/sessions/<session_id>")
@app.get("/sessions/<session_id>")
def get_session(session_id: str) -> Any:
    row = _read("sessions", session_id)
    if not row:
        return jsonify({"error": "session not found"}), 404
    return jsonify(row)


@app.delete("/api/sessions/<session_id>")
@app.delete("/sessions/<session_id>")
def delete_session(session_id: str) -> Any:
    if not _read("sessions", session_id):
        return jsonify({"error": "session not found"}), 404
    for msg in _list("messages"):
        if msg.get("session_id") == session_id:
            _delete("messages", msg["id"])
    _delete("sessions", session_id)
    return jsonify({"id": session_id, "deleted": True})


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

@app.post("/api/sessions/<session_id>/messages")
@app.post("/sessions/<session_id>/messages")
def create_message(session_id: str) -> Any:
    body = request.get_json(silent=True) or {}
    role = body.get("role")
    content = body.get("content")
    if role not in ("user", "assistant"):
        return jsonify({"error": "role must be 'user' or 'assistant'"}), 400
    if not isinstance(content, str) or not content.strip():
        return jsonify({"error": "content is required"}), 400

    msg_id = body.get("id") or str(uuid.uuid4())
    existing = _read("messages", msg_id)
    if existing:
        return jsonify(existing), 201

    # Auto-create session if needed
    if not _read("sessions", session_id):
        ts = _now()
        _save("sessions", {
            "id": session_id, "created_at": ts, "updated_at": ts,
            "name": "Untitled", "model": "gpt-5.2", "status": "active",
            "last_message_at": None,
        })

    ts = _now()
    row = {
        "id": msg_id,
        "session_id": session_id,
        "created_at": ts,
        "role": role,
        "content": content.strip(),
        "device_id": body.get("device_id"),
    }
    _save("messages", row)

    session = _read("sessions", session_id)
    if session:
        session["last_message_at"] = ts
        session["updated_at"] = ts
        _save("sessions", session)

    return jsonify(row), 201


@app.get("/api/sessions/<session_id>/messages")
@app.get("/sessions/<session_id>/messages")
def list_messages(session_id: str) -> Any:
    limit = min(int(request.args.get("limit", 200)), 200)
    since = request.args.get("since")
    rows = [m for m in _list("messages") if m.get("session_id") == session_id]
    if since:
        rows = [m for m in rows if m.get("created_at", "") > since]
    rows.sort(key=lambda m: m.get("created_at", ""))
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

@app.post("/api/screenshots")
def upload_screenshot() -> Any:
    if "screenshot" not in request.files:
        return jsonify({"error": "screenshot file required"}), 400
    shot = request.files["screenshot"]
    if not shot.filename:
        return jsonify({"error": "empty filename"}), 400
    mime = shot.content_type or ""
    if not mime.startswith("image/"):
        return jsonify({"error": "must be an image"}), 400

    screenshot_id = str(uuid.uuid4())
    ts = _now()
    device_id = request.form.get("device_id")
    session_id = (request.form.get("session_id") or "").strip() or None
    source = request.form.get("source")
    notes = request.form.get("notes")

    ext = Path(secure_filename(shot.filename)).suffix or ".png"
    safe_device = secure_filename(device_id or "unknown")
    device_dir = SCREENSHOTS_DIR / safe_device
    device_dir.mkdir(parents=True, exist_ok=True)
    file_path = device_dir / f"{screenshot_id}{ext}"
    shot.save(file_path)

    row = {
        "id": screenshot_id,
        "created_at": ts,
        "session_id": session_id,
        "device_id": device_id,
        "source": source,
        "mime_type": mime,
        "file_path": str(file_path),
        "notes": notes,
    }
    _save("screenshots", row)
    return jsonify(row), 201


@app.get("/api/screenshots")
def list_screenshots() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    device_id = request.args.get("device_id")
    session_id = (request.args.get("session_id") or "").strip() or None
    rows = _list("screenshots")
    if device_id:
        rows = [r for r in rows if r.get("device_id") == device_id]
    if session_id:
        rows = [r for r in rows if r.get("session_id") == session_id]
    rows.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.get("/api/screenshots/<screenshot_id>")
def get_screenshot(screenshot_id: str) -> Any:
    row = _read("screenshots", screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    return jsonify(row)


@app.get("/api/screenshots/<screenshot_id>/file")
def get_screenshot_file(screenshot_id: str) -> Any:
    row = _read("screenshots", screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    fp = Path(row.get("file_path", ""))
    if not fp.exists():
        return jsonify({"error": "file missing"}), 410
    return send_file(fp, mimetype=row.get("mime_type", "application/octet-stream"))


@app.delete("/api/screenshots/<screenshot_id>")
def delete_screenshot(screenshot_id: str) -> Any:
    row = _read("screenshots", screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    _delete("screenshots", screenshot_id)
    fp = Path(row.get("file_path", ""))
    fp.unlink(missing_ok=True)
    return jsonify({"id": screenshot_id, "deleted": True})


# ---------------------------------------------------------------------------
# Devices
# ---------------------------------------------------------------------------

@app.post("/devices")
def register_device() -> Any:
    body = request.get_json(silent=True) or {}
    device_id = body.get("id")
    if not device_id:
        return jsonify({"error": "id is required"}), 400
    device_registry[device_id] = body
    return jsonify({"registered": True, "device_id": device_id})


@app.get("/devices")
def list_devices() -> Any:
    return jsonify({"devices": list(device_registry.values()), "count": len(device_registry)})


@app.delete("/devices/<device_id>")
def unregister_device(device_id: str) -> Any:
    if device_id in device_registry:
        del device_registry[device_id]
        return jsonify({"unregistered": device_id})
    return jsonify({"error": "not found"}), 404


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

IPAD_PLATFORMS = {"ipados", "ipad", "ios"}


def _deliver_widget_to_ipad(widget: dict) -> str | None:
    """POST widget to a registered iPad. Returns status or None."""
    for dev in device_registry.values():
        if (dev.get("platform") or "").lower() in IPAD_PLATFORMS:
            host, port = dev["host"], dev["port"]
            try:
                resp = httpx.post(
                    f"http://{host}:{port}/api/v1/objects",
                    json={
                        "html": widget.get("html", ""),
                        "width": widget.get("width", 320),
                        "height": widget.get("height", 220),
                    },
                    timeout=10,
                )
                if resp.status_code in (200, 201):
                    return f"Delivered to iPad ({dev.get('name', host)})"
                return f"iPad returned {resp.status_code}"
            except httpx.HTTPError as exc:
                return f"iPad delivery failed: {exc}"
    return None


@app.post("/v1/agent")
def v1_agent() -> Any:
    body = request.get_json(silent=True) or {}

    session_id = (body.get("session_id") or "").strip()
    if not session_id:
        return jsonify({"error": "session_id is required"}), 400

    input_data = body.get("input") or {}
    if input_data.get("type") != "text":
        return jsonify({"error": "input.type must be 'text'"}), 400
    message = (input_data.get("text") or "").strip()
    if not message:
        return jsonify({"error": "input.text is required"}), 400

    model = (body.get("model") or "").strip() or "gpt-5.2"
    device = body.get("device") or {}
    device_platform = (device.get("platform") or "").lower()

    # Ensure session exists
    if not _read("sessions", session_id):
        ts = _now()
        _save("sessions", {
            "id": session_id, "created_at": ts, "updated_at": ts,
            "name": session_id, "model": model, "status": "active",
            "last_message_at": None,
        })

    # Load message history
    all_msgs = [m for m in _list("messages") if m.get("session_id") == session_id]
    all_msgs.sort(key=lambda m: m.get("created_at", ""))
    context = [{"role": m["role"], "content": m["content"]} for m in all_msgs]

    # If empty and caller sent context, seed from it
    if not context:
        recent = (body.get("context") or {}).get("recent_messages") or []
        for msg in recent[-20:]:
            role = (msg.get("role") or "").strip()
            text = (msg.get("text") or "").strip()
            if role in ("user", "assistant") and text:
                context.append({"role": role, "content": text})

    # Save user message
    ts = _now()
    _save("messages", {
        "id": str(uuid.uuid4()),
        "session_id": session_id,
        "created_at": ts,
        "role": "user",
        "content": message,
        "device_id": device.get("id"),
    })

    # Call agent
    result = agent_module.run(context, message, model=model)

    # Save assistant response
    ts = _now()
    _save("messages", {
        "id": str(uuid.uuid4()),
        "session_id": session_id,
        "created_at": ts,
        "role": "assistant",
        "content": result["text"],
        "device_id": None,
    })

    # Update session
    session = _read("sessions", session_id)
    if session:
        session["updated_at"] = ts
        session["last_message_at"] = ts
        _save("sessions", session)

    # Build widget events + deliver
    events: list[dict] = []
    for w in result.get("widgets", []):
        # Always try iPad delivery if any iPad is registered
        _deliver_widget_to_ipad(w)

        events.append({
            "kind": "widget.open",
            "widget": {
                "kind": "html",
                "id": w.get("widget_id"),
                "payload": {"html": w.get("html", "")},
                "width": w.get("width"),
                "height": w.get("height"),
            },
        })

    return jsonify({
        "kind": "message.final",
        "request_id": body.get("request_id", ""),
        "session_id": session_id,
        "model": model,
        "text": result["text"],
        "events": events,
        "timestamp": _now(),
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port, debug=True)

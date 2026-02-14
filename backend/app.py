"""Iris backend — single-JSON-per-session storage."""
from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request, send_file
from werkzeug.utils import secure_filename
from orchestration import (
    apply_arrow_tip_policy,
    build_widget_events,
    normalize_widget_specs,
    requests_widget,
    sanitize_coordinate_snapshot,
)

def _load_root_env() -> None:
    """Load environment variables from repository root .env if present."""
    root_env = Path(__file__).resolve().parent.parent / ".env"
    if not root_env.exists():
        return
    for raw in root_env.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
            if "=" not in line:
                continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        os.environ[key] = value


_load_root_env()

import agent as agent_module

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SESSIONS_DIR = DATA_DIR / "sessions"
SCREENSHOTS_DIR = DATA_DIR / "screenshots"

for d in [SESSIONS_DIR, SCREENSHOTS_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Session storage — one JSON file per session
#
# Each file: {
#   "id", "name", "model", "created_at", "updated_at",
#   "messages": [{"id", "role", "content", "created_at"}, ...],
#   "widgets":  [{"id", "html", "width", "height", "created_at"}, ...]
# }
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session_path(session_id: str) -> Path:
    return SESSIONS_DIR / f"{session_id}.json"


def _load_session(session_id: str) -> dict | None:
    try:
        data = json.loads(_session_path(session_id).read_text())
        return data if isinstance(data, dict) else None
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _save_session(session: dict) -> None:
    path = _session_path(session["id"])
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(session, ensure_ascii=False, indent=2))
    tmp.replace(path)


def _list_sessions() -> list[dict]:
    rows = []
    for p in SESSIONS_DIR.glob("*.json"):
        try:
            data = json.loads(p.read_text())
            if isinstance(data, dict):
                rows.append(data)
        except (json.JSONDecodeError, OSError):
            continue
    return rows


def _delete_session(session_id: str) -> bool:
    try:
        _session_path(session_id).unlink()
        return True
    except FileNotFoundError:
        return False


def _make_session(session_id: str, name: str = "Untitled", model: str = "gpt-5.2") -> dict:
    ts = _now()
    return {
        "id": session_id,
        "name": name,
        "model": model,
        "created_at": ts,
        "updated_at": ts,
        "messages": [],
        "widgets": [],
    }


def _session_summary(session: dict) -> dict:
    """Return session metadata without the full messages array (for listings)."""
    return {
        "id": session["id"],
        "name": session.get("name", "Untitled"),
        "model": session.get("model", "gpt-5.2"),
        "created_at": session.get("created_at", ""),
        "updated_at": session.get("updated_at", ""),
    }


def _spatial_context_text(metadata: dict[str, Any] | None) -> str:
    if not isinstance(metadata, dict):
        return ""
    snapshot = metadata.get("coordinate_snapshot")
    if not isinstance(snapshot, dict):
        return ""
    try:
        return (
            "Coordinate snapshot (document_axis): "
            + json.dumps(snapshot, ensure_ascii=False)
        )
    except (TypeError, ValueError):
        return ""



# ---------------------------------------------------------------------------
# Screenshot storage helpers (kept simple — separate files)
# ---------------------------------------------------------------------------
SCREENSHOTS_META_DIR = DATA_DIR / "screenshot_meta"
SCREENSHOTS_META_DIR.mkdir(parents=True, exist_ok=True)
PROACTIVE_DESCRIPTIONS_DIR = DATA_DIR / "proactive_descriptions"
PROACTIVE_DESCRIPTIONS_DIR.mkdir(parents=True, exist_ok=True)


def _screenshot_meta_path(screenshot_id: str) -> Path:
    return SCREENSHOTS_META_DIR / f"{screenshot_id}.json"


def _load_screenshot(screenshot_id: str) -> dict | None:
    try:
        return json.loads(_screenshot_meta_path(screenshot_id).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _save_screenshot(row: dict) -> None:
    path = _screenshot_meta_path(row["id"])
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(row, ensure_ascii=False))
    tmp.replace(path)


def _list_screenshots() -> list[dict]:
    rows = []
    for p in SCREENSHOTS_META_DIR.glob("*.json"):
        try:
            data = json.loads(p.read_text())
            if isinstance(data, dict):
                rows.append(data)
        except (json.JSONDecodeError, OSError):
            continue
    return rows


def _save_proactive_description(payload: dict[str, Any]) -> None:
    screenshot_id = str(payload.get("screenshot_id") or "").strip()
    if not screenshot_id:
        return
    path = PROACTIVE_DESCRIPTIONS_DIR / f"{screenshot_id}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False))
    tmp.replace(path)


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
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

@app.post("/api/sessions")
@app.post("/sessions")
def create_session() -> Any:
    body = request.get_json(silent=True) or {}
    session_id = (body.get("id") or "").strip() or str(uuid.uuid4())
    model = (body.get("model") or body.get("agent") or "gpt-5.2").strip()
    name = (body.get("name") or "Untitled").strip()

    existing = _load_session(session_id)
    if existing:
        existing["updated_at"] = _now()
        if body.get("name"):
            existing["name"] = name
        if body.get("model") or body.get("agent"):
            existing["model"] = model
        _save_session(existing)
        return jsonify(_session_summary(existing)), 201

    session = _make_session(session_id, name, model)
    _save_session(session)
    return jsonify(_session_summary(session)), 201


@app.get("/api/sessions")
@app.get("/sessions")
def list_sessions() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = [_session_summary(s) for s in _list_sessions()]
    rows.sort(key=lambda r: r.get("updated_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.get("/api/sessions/<session_id>")
@app.get("/sessions/<session_id>")
def get_session(session_id: str) -> Any:
    session = _load_session(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404

    target_filter = (request.args.get("target") or "").strip().lower()
    if target_filter:
        session = {**session}  # shallow copy
        session["widgets"] = [
            w for w in session.get("widgets", [])
            if w.get("target", "mac") == target_filter
        ]

    return jsonify(session)


@app.delete("/api/sessions/<session_id>/widgets/<widget_id>")
@app.delete("/sessions/<session_id>/widgets/<widget_id>")
def delete_widget(session_id: str, widget_id: str) -> Any:
    session = _load_session(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404
    widgets = session.get("widgets", [])
    before = len(widgets)
    session["widgets"] = [w for w in widgets if w.get("id") != widget_id]
    if len(session["widgets"]) == before:
        return jsonify({"error": "widget not found"}), 404
    session["updated_at"] = _now()
    _save_session(session)
    return jsonify({"id": widget_id, "deleted": True})

@app.delete("/api/sessions/<session_id>")
@app.delete("/sessions/<session_id>")
def delete_session(session_id: str) -> Any:
    if not _load_session(session_id):
        return jsonify({"error": "session not found"}), 404
    _delete_session(session_id)
    return jsonify({"id": session_id, "deleted": True})


# ---------------------------------------------------------------------------
# Messages (read/write from the session's messages array)
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

    session = _load_session(session_id)
    if not session:
        session = _make_session(session_id)

    msg_id = body.get("id") or str(uuid.uuid4())

    # Dedup by id
    if any(m.get("id") == msg_id for m in session.get("messages", [])):
        existing_msg = next(m for m in session["messages"] if m.get("id") == msg_id)
        return jsonify(existing_msg), 201

    ts = _now()
    msg = {
        "id": msg_id,
        "role": role,
        "content": content.strip(),
        "created_at": ts,
        "device_id": body.get("device_id"),
    }
    session.setdefault("messages", []).append(msg)
    session["updated_at"] = ts
    _save_session(session)
    return jsonify(msg), 201


@app.get("/api/sessions/<session_id>/messages")
@app.get("/sessions/<session_id>/messages")
def list_messages(session_id: str) -> Any:
    limit = min(int(request.args.get("limit", 200)), 200)
    since = request.args.get("since")

    session = _load_session(session_id)
    if not session:
        return jsonify({"items": [], "count": 0})

    msgs = session.get("messages", [])
    if since:
        msgs = [m for m in msgs if m.get("created_at", "") > since]

    return jsonify({"items": msgs[:limit], "count": min(len(msgs), limit)})


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
    coordinate_snapshot_raw = request.form.get("coordinate_snapshot")
    coordinate_snapshot: dict[str, Any] | None = None
    if isinstance(coordinate_snapshot_raw, str) and coordinate_snapshot_raw.strip():
        try:
            coordinate_snapshot = sanitize_coordinate_snapshot(json.loads(coordinate_snapshot_raw))
        except json.JSONDecodeError:
            coordinate_snapshot = None

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
        "coordinate_snapshot": coordinate_snapshot,
    }
    _save_screenshot(row)
    return jsonify(row), 201


@app.get("/api/screenshots")
def list_screenshots_endpoint() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    device_id = request.args.get("device_id")
    session_id = (request.args.get("session_id") or "").strip() or None
    rows = _list_screenshots()
    if device_id:
        rows = [r for r in rows if r.get("device_id") == device_id]
    if session_id:
        rows = [r for r in rows if r.get("session_id") == session_id]
    rows.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.get("/api/screenshots/<screenshot_id>")
def get_screenshot(screenshot_id: str) -> Any:
    row = _load_screenshot(screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    return jsonify(row)


@app.get("/api/screenshots/<screenshot_id>/file")
def get_screenshot_file(screenshot_id: str) -> Any:
    row = _load_screenshot(screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    fp = Path(row.get("file_path", ""))
    if not fp.exists():
        return jsonify({"error": "file missing"}), 410
    return send_file(fp, mimetype=row.get("mime_type", "application/octet-stream"))


@app.post("/api/proactive/describe")
def proactive_describe_screenshot() -> Any:
    body = request.get_json(silent=True) or {}
    screenshot_id = str(body.get("screenshot_id") or "").strip()
    if not screenshot_id:
        return jsonify({"error": "screenshot_id is required"}), 400

    row = _load_screenshot(screenshot_id)
    if not row:
        return jsonify({"error": "screenshot not found"}), 404

    fp = Path(str(row.get("file_path") or ""))
    if not fp.exists():
        return jsonify({"error": "screenshot file missing"}), 410

    coordinate_snapshot = sanitize_coordinate_snapshot(body.get("coordinate_snapshot"))

    previous_description = body.get("previous_description")
    if not isinstance(previous_description, dict):
        previous_description = None

    try:
        description = agent_module.describe_screenshot_with_gemini(
            fp,
            str(row.get("mime_type") or "image/png"),
            coordinate_snapshot=coordinate_snapshot,
            previous_description=previous_description,
        )
    except Exception as exc:
        return jsonify({"error": f"description failed: {exc}"}), 500

    result = {
        "screenshot_id": screenshot_id,
        "session_id": row.get("session_id"),
        "device_id": row.get("device_id"),
        "created_at": _now(),
        "model": os.environ.get("PROACTIVE_GEMINI_MODEL", agent_module.DEFAULT_GEMINI_MODEL),
        "description": description,
    }
    _save_proactive_description(result)
    return jsonify(result), 200



@app.delete("/api/screenshots/<screenshot_id>")
def delete_screenshot(screenshot_id: str) -> Any:
    row = _load_screenshot(screenshot_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    _screenshot_meta_path(screenshot_id).unlink(missing_ok=True)
    fp = Path(row.get("file_path", ""))
    fp.unlink(missing_ok=True)
    return jsonify({"id": screenshot_id, "deleted": True})


# ---------------------------------------------------------------------------
# Transcripts (no-op — iPad sends these, we just accept and discard)
# ---------------------------------------------------------------------------

@app.post("/api/transcripts")
def ingest_transcript() -> Any:
    return jsonify({"ok": True}), 201


# ---------------------------------------------------------------------------
# Devices (kept for client compat — no-op registry)
# ---------------------------------------------------------------------------

@app.post("/devices")
def register_device() -> Any:
    return jsonify({"registered": True, "device_id": (request.get_json(silent=True) or {}).get("id")})

@app.get("/devices")
def list_devices() -> Any:
    return jsonify({"devices": [], "count": 0})

@app.delete("/devices/<device_id>")
def unregister_device(device_id: str) -> Any:
    return jsonify({"unregistered": device_id})


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

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
    metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
    metadata = dict(metadata)
    coordinate_snapshot_valid = False
    if "coordinate_snapshot" in metadata:
        metadata["coordinate_snapshot"] = sanitize_coordinate_snapshot(metadata.get("coordinate_snapshot"))
        coordinate_snapshot_valid = isinstance(metadata.get("coordinate_snapshot"), dict)

    # Load or create session
    session = _load_session(session_id)
    if not session:
        session = _make_session(session_id, session_id, model)

    # Build context from session messages
    context = [{"role": m["role"], "content": m["content"]} for m in session.get("messages", [])]

    # If empty and caller sent context, seed from it
    if not context:
        recent = (body.get("context") or {}).get("recent_messages") or []
        for msg in recent[-20:]:
            role = (msg.get("role") or "").strip()
            text = (msg.get("text") or "").strip()
            if role in ("user", "assistant") and text:
                context.append({"role": role, "content": text})

    # Append user message
    ts = _now()
    session.setdefault("messages", []).append({
        "id": str(uuid.uuid4()),
        "role": "user",
        "content": message,
        "created_at": ts,
        "device_id": device.get("id"),
    })

    # Prepend device info so the agent knows which device is asking
    device_name = device.get("name", "unknown")
    device_platform = device.get("platform", "unknown")
    augmented_message = f"[Device: {device_name} ({device_platform})]\n{message}"

    # Append optional spatial context from caller metadata.
    spatial_note = _spatial_context_text(metadata)
    if spatial_note:
        augmented_message = f"{augmented_message}\n\n{spatial_note}"

    # Call agent
    preferred_device = "ipad" if str(device.get("platform", "")).lower().startswith("ipad") else "mac"
    result = agent_module.run(
        context,
        augmented_message,
        model=model,
        session_id=session_id,
        preferred_device=preferred_device,
    )

    # Deterministic fallback for explicit widget asks: never silently "describe" without creating.
    widget_forced = False
    if requests_widget(message) and not result.get("widgets"):
        fallback_widget = agent_module.generate_widget_from_prompt(
            context=context,
            user_message=augmented_message,
            model=model,
            preferred_device=preferred_device,
        )
        if fallback_widget:
            result.setdefault("widgets", []).append(fallback_widget)
            widget_forced = True

    # Append assistant response
    ts = _now()
    assistant_msg: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "role": "assistant",
        "content": result["text"],
        "created_at": ts,
        "device_id": None,
    }
    if result.get("tool_calls"):
        assistant_msg["tool_calls"] = result["tool_calls"]
    session["messages"].append(assistant_msg)

    # Store widgets in session
    events: list[dict] = []

    # Emit tool_call events
    for tc in result.get("tool_calls", []):
        events.append({
            "kind": "tool_call",
            "tool_call": tc,
        })
    fallback_target = "ipad" if str(device.get("platform", "")).lower().startswith("ipad") else "mac"
    normalized_widgets = normalize_widget_specs(result.get("widgets", []), fallback_target=fallback_target)
    arrow_policy = apply_arrow_tip_policy(
        normalized_widgets,
        message=message,
        device=fallback_target,
        session_id=session_id,
    )
    widget_records, widget_events = build_widget_events(normalized_widgets)
    for widget_record in widget_records:
        widget_record["created_at"] = ts
        session.setdefault("widgets", []).append(widget_record)
    events.extend(widget_events)

    session["updated_at"] = ts
    _save_session(session)

    return jsonify({
        "kind": "message.final",
        "request_id": body.get("request_id", ""),
        "session_id": session_id,
        "model": model,
        "text": result["text"],
        "events": events,
        "meta": {
            "widget_forced": widget_forced,
            "coordinate_snapshot_valid": coordinate_snapshot_valid,
            "widget_count": len(widget_records),
            "tool_call_count": len(result.get("tool_calls", [])),
            "arrow_policy": arrow_policy,
        },
        "timestamp": _now(),
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port, debug=True)

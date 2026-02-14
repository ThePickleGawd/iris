from __future__ import annotations

import json
import os
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request, send_file, url_for
from werkzeug.exceptions import RequestEntityTooLarge
from werkzeug.utils import secure_filename


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
STORE_DIR = DATA_DIR / "store"
SCREENSHOTS_DIR = DATA_DIR / "screenshots"
MAX_REQUEST_BYTES = 15 * 1024 * 1024
MAX_TRANSCRIPT_CHARS = 20_000
MAX_LIST_LIMIT = 200
DEFAULT_LIST_LIMIT = 50
GLOBAL_RATE_LIMIT_PER_MINUTE = 120
SCREENSHOT_UPLOAD_RATE_LIMIT_PER_MINUTE = 30
ALLOWED_SCREENSHOT_MIME_PREFIX = "image/"
CORS_ALLOW_ORIGIN = os.environ.get("CORS_ALLOW_ORIGIN", "*").strip() or "*"
CORS_ALLOW_METHODS = "GET,POST,PUT,DELETE,OPTIONS"
CORS_ALLOW_HEADERS = "Content-Type, Authorization, X-Requested-With"
CORS_MAX_AGE_SECONDS = "600"
CURSOR_SEPARATOR = "|"
COMMAND_STATUS_QUEUED = "queued"
COMMAND_STATUS_IN_PROGRESS = "in_progress"
COMMAND_STATUS_COMPLETED = "completed"
COMMAND_STATUS_FAILED = "failed"
COMMAND_STATUS_CANCELED = "canceled"
COMMAND_STATUSES = {
    COMMAND_STATUS_QUEUED,
    COMMAND_STATUS_IN_PROGRESS,
    COMMAND_STATUS_COMPLETED,
    COMMAND_STATUS_FAILED,
    COMMAND_STATUS_CANCELED,
}
SESSION_STATUS_ACTIVE = "active"
SESSION_STATUS_ARCHIVED = "archived"
SESSION_STATUSES = {SESSION_STATUS_ACTIVE, SESSION_STATUS_ARCHIVED}
STORE_ENTITIES = (
    "sessions",
    "messages",
    "transcripts",
    "screenshots",
    "device_commands",
    "agent_status",
)

RATE_LIMIT_STATE: dict[str, list[float]] = {}
RATE_LIMIT_LOCK = threading.Lock()
STORE_LOCK = threading.RLock()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dirs() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    STORE_DIR.mkdir(exist_ok=True)
    SCREENSHOTS_DIR.mkdir(exist_ok=True)
    for entity in STORE_ENTITIES:
        entity_dir(entity).mkdir(parents=True, exist_ok=True)


def entity_dir(entity: str) -> Path:
    return STORE_DIR / entity


def entity_path(entity: str, item_id: str) -> Path:
    return entity_dir(entity) / f"{item_id}.json"


def read_json_file(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_records(entity: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with STORE_LOCK:
        for path in sorted(entity_dir(entity).glob("*.json")):
            row = read_json_file(path)
            if row is not None:
                rows.append(row)
    return rows


def get_record(entity: str, item_id: str) -> dict[str, Any] | None:
    with STORE_LOCK:
        return read_json_file(entity_path(entity, item_id))


def save_record(entity: str, row: dict[str, Any]) -> None:
    item_id = row.get("id")
    if not isinstance(item_id, str) or not item_id.strip():
        raise ValueError("record id is required")

    path = entity_path(entity, item_id)
    tmp_path = path.with_suffix(".json.tmp")
    payload = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    with STORE_LOCK:
        tmp_path.write_text(payload, encoding="utf-8")
        tmp_path.replace(path)


def delete_record(entity: str, item_id: str) -> bool:
    path = entity_path(entity, item_id)
    try:
        with STORE_LOCK:
            path.unlink()
        return True
    except FileNotFoundError:
        return False


def parse_iso8601_to_utc(ts: str) -> str:
    normalized = ts.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    else:
        parsed = parsed.astimezone(timezone.utc)
    return parsed.isoformat()


def to_dt(ts: Any) -> datetime:
    if isinstance(ts, str) and ts.strip():
        try:
            return datetime.fromisoformat(parse_iso8601_to_utc(ts))
        except ValueError:
            pass
    return datetime.fromtimestamp(0, tz=timezone.utc)


def parse_list_limit(raw_limit: str | None) -> int:
    if raw_limit is None or not raw_limit.strip():
        return DEFAULT_LIST_LIMIT
    cleaned = raw_limit.strip()
    if not cleaned.isdigit():
        raise ValueError("limit must be a positive integer")
    limit = int(cleaned)
    if limit <= 0:
        raise ValueError("limit must be greater than 0")
    return min(limit, MAX_LIST_LIMIT)


def parse_since(raw_since: str | None) -> str | None:
    if raw_since is None or not raw_since.strip():
        return None
    return parse_iso8601_to_utc(raw_since)


def parse_cursor(raw_cursor: str | None) -> tuple[str | None, str | None]:
    if raw_cursor is None or not raw_cursor.strip():
        return None, None
    token = raw_cursor.strip()
    if CURSOR_SEPARATOR not in token:
        raise ValueError("cursor must be in the format '<iso-ts>|<id>'")
    ts_raw, item_id = token.split(CURSOR_SEPARATOR, 1)
    ts_raw = ts_raw.replace(" ", "+")
    ts = parse_iso8601_to_utc(ts_raw)
    if not item_id.strip():
        raise ValueError("cursor id cannot be empty")
    return ts, item_id.strip()


def parse_paging_cursor(raw_cursor: str | None, raw_since: str | None) -> tuple[str | None, str | None]:
    if raw_cursor and raw_cursor.strip():
        return parse_cursor(raw_cursor)
    return parse_since(raw_since), None


def make_cursor(ts: str, item_id: str) -> str:
    cursor_ts = ts.replace("+00:00", "Z")
    return f"{cursor_ts}{CURSOR_SEPARATOR}{item_id}"


def cursor_allows(ts: str, item_id: str, cursor_ts: str | None, cursor_id: str | None) -> bool:
    if cursor_ts is None:
        return True
    row_dt = to_dt(ts)
    cursor_dt = to_dt(cursor_ts)
    if row_dt > cursor_dt:
        return True
    if row_dt < cursor_dt:
        return False
    if cursor_id is None:
        return False
    return item_id > cursor_id


def check_rate_limit(key: str, limit: int, window_seconds: int = 60) -> tuple[bool, int]:
    now = time.time()
    cutoff = now - window_seconds
    with RATE_LIMIT_LOCK:
        timestamps = RATE_LIMIT_STATE.get(key, [])
        timestamps = [t for t in timestamps if t >= cutoff]
        if len(timestamps) >= limit:
            retry_after = int(max(1, window_seconds - (now - timestamps[0])))
            RATE_LIMIT_STATE[key] = timestamps
            return False, retry_after
        timestamps.append(now)
        RATE_LIMIT_STATE[key] = timestamps
    return True, 0


def parse_optional_session_id(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("session_id must be a string")
    cleaned = value.strip()
    if not cleaned:
        raise ValueError("session_id cannot be empty")
    return cleaned


def ensure_session_exists(session_id: str) -> bool:
    return get_record("sessions", session_id) is not None


def parse_session_status(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("status is required")
    cleaned = value.strip()
    if cleaned not in SESSION_STATUSES:
        raise ValueError("status must be one of: active, archived")
    return cleaned


def parse_session_status_filter(value: str | None) -> str | None:
    if value is None or not value.strip():
        return None
    cleaned = value.strip()
    if cleaned not in SESSION_STATUSES:
        raise ValueError("status must be one of: active, archived")
    return cleaned


def touch_session(session_id: str | None) -> None:
    if not session_id:
        return
    row = get_record("sessions", session_id)
    if not row:
        return
    row["updated_at"] = now_iso()
    save_record("sessions", row)


def session_to_dict(row: dict[str, Any]) -> dict[str, Any]:
    metadata = row.get("metadata")
    if not isinstance(metadata, (dict, list)):
        metadata = {}
    return {
        "id": row.get("id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "name": row.get("name"),
        "agent": row.get("agent", "iris"),
        "status": row.get("status"),
        "device_id": row.get("device_id"),
        "source_device_id": row.get("source_device_id"),
        "last_message_at": row.get("last_message_at"),
        "metadata": metadata,
    }


def transcript_to_dict(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row.get("id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "captured_at": row.get("captured_at"),
        "session_id": row.get("session_id"),
        "device_id": row.get("device_id"),
        "source": row.get("source"),
        "text": row.get("text"),
    }


def screenshot_to_dict(row: dict[str, Any]) -> dict[str, Any]:
    file_url = url_for("get_screenshot_file", screenshot_id=str(row.get("id")), _external=True)
    return {
        "id": row.get("id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "captured_at": row.get("captured_at"),
        "session_id": row.get("session_id"),
        "device_id": row.get("device_id"),
        "source": row.get("source"),
        "mime_type": row.get("mime_type"),
        "file_path": row.get("file_path"),
        "file_url": file_url,
        "notes": row.get("notes"),
    }


def command_to_dict(row: dict[str, Any]) -> dict[str, Any]:
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    return {
        "id": row.get("id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "target_device_id": row.get("target_device_id"),
        "session_id": row.get("session_id"),
        "source_device_id": row.get("source_device_id"),
        "command_type": row.get("command_type"),
        "payload": payload,
        "status": row.get("status"),
        "acknowledged_at": row.get("acknowledged_at"),
        "completed_at": row.get("completed_at"),
        "result": row.get("result"),
        "error": row.get("error"),
    }


def agent_status_to_dict(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    metadata = row.get("metadata")
    if not isinstance(metadata, (dict, list)):
        metadata = {}
    return {
        "id": row.get("id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "session_id": row.get("session_id"),
        "phase": row.get("phase"),
        "headline": row.get("headline"),
        "detail": row.get("detail"),
        "source_device_id": row.get("source_device_id"),
        "metadata": metadata,
    }


def message_to_dict(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row.get("id"),
        "session_id": row.get("session_id"),
        "created_at": row.get("created_at"),
        "role": row.get("role"),
        "content": row.get("content"),
        "device_id": row.get("device_id"),
    }


def parse_status_list(raw_statuses: str | None, default_statuses: set[str]) -> list[str]:
    if raw_statuses is None or not raw_statuses.strip():
        return sorted(default_statuses)
    statuses = [part.strip() for part in raw_statuses.split(",") if part.strip()]
    if not statuses:
        return sorted(default_statuses)
    invalid = [status for status in statuses if status not in COMMAND_STATUSES]
    if invalid:
        raise ValueError("invalid status values")
    return sorted(set(statuses))


def delete_files(paths: list[Path]) -> dict[str, int]:
    removed = 0
    missing = 0
    failed = 0
    for path in paths:
        try:
            path.unlink()
            removed += 1
        except FileNotFoundError:
            missing += 1
        except OSError:
            failed += 1
    return {"removed": removed, "missing": missing, "failed": failed}


def screenshot_device_dir(device_id: str | None) -> Path:
    name = (device_id or "").strip()
    safe_name = secure_filename(name) if name else ""
    if not safe_name:
        safe_name = "unknown-device"
    return SCREENSHOTS_DIR / safe_name


def normalize_screenshot_device_id(device_id: str | None, source: str | None) -> str | None:
    """Normalize screenshot device ids so Mac captures are always grouped under 'mac'."""
    cleaned_device = (device_id or "").strip() or None
    cleaned_source = (source or "").strip().lower() or None

    mac_sources = {
        "manual",
        "screen-monitor",
        "chat-context",
        "image-analysis",
        "image-analysis-inline",
        "extract-problem",
        "debug-screenshot",
    }
    if cleaned_source in mac_sources:
        return "mac"

    if cleaned_device:
        lowered = cleaned_device.lower()
        if lowered == "mac" or lowered.startswith("mac-") or lowered.startswith("iris-mac"):
            return "mac"

    return cleaned_device


def newest_record(rows: list[dict[str, Any]], ts_key: str = "updated_at") -> dict[str, Any] | None:
    if not rows:
        return None
    return max(rows, key=lambda row: (to_dt(row.get(ts_key)), str(row.get("id", ""))))


def create_app() -> Flask:
    ensure_dirs()

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES

    @app.after_request
    def apply_cors_headers(response: Any) -> Any:
        if request.path.startswith("/api/"):
            response.headers["Access-Control-Allow-Origin"] = CORS_ALLOW_ORIGIN
            response.headers["Access-Control-Allow-Methods"] = CORS_ALLOW_METHODS
            response.headers["Access-Control-Allow-Headers"] = CORS_ALLOW_HEADERS
            response.headers["Access-Control-Max-Age"] = CORS_MAX_AGE_SECONDS
            if CORS_ALLOW_ORIGIN != "*":
                response.headers["Vary"] = "Origin"
        return response

    @app.before_request
    def apply_basic_guards() -> Any:
        if request.path == "/health":
            return None
        if not request.path.startswith("/api/"):
            return None
        if request.method == "OPTIONS":
            return ("", 204)

        forwarded = request.headers.get("X-Forwarded-For", "")
        client_ip = forwarded.split(",")[0].strip() if forwarded else (request.remote_addr or "unknown")
        limit = GLOBAL_RATE_LIMIT_PER_MINUTE
        if request.method == "POST" and request.path == "/api/screenshots":
            limit = SCREENSHOT_UPLOAD_RATE_LIMIT_PER_MINUTE

        allowed, retry_after = check_rate_limit(
            key=f"{client_ip}:{request.method}:{request.path}",
            limit=limit,
        )
        if not allowed:
            return (
                jsonify({
                    "error": "rate limit exceeded",
                    "retry_after_seconds": retry_after,
                }),
                429,
                {"Retry-After": str(retry_after)},
            )
        return None

    @app.errorhandler(RequestEntityTooLarge)
    def handle_request_too_large(_: RequestEntityTooLarge) -> Any:
        return (
            jsonify({
                "error": "request too large",
                "max_bytes": MAX_REQUEST_BYTES,
            }),
            413,
        )

    @app.get("/health")
    def health() -> Any:
        return jsonify({"status": "ok", "ts": now_iso()})

    @app.post("/api/sessions")
    def create_session() -> Any:
        payload = request.get_json(silent=True) or {}
        name = payload.get("name")
        source_device_id = payload.get("source_device_id")
        device_id = payload.get("device_id")
        metadata = payload.get("metadata", {})
        agent = payload.get("agent")

        session_name = "Untitled Session"
        if isinstance(name, str) and name.strip():
            session_name = name.strip()

        if not isinstance(metadata, (dict, list)):
            metadata = {}

        # Accept optional caller-provided id (for iPad registration)
        session_id = payload.get("id")
        if isinstance(session_id, str) and session_id.strip():
            session_id = session_id.strip()
            # Idempotent: if session already exists, update and return it
            existing = get_record("sessions", session_id)
            if existing:
                existing["updated_at"] = now_iso()
                if isinstance(name, str) and name.strip():
                    existing["name"] = name.strip()
                if isinstance(agent, str) and agent.strip():
                    existing["agent"] = agent.strip()
                if isinstance(device_id, str):
                    existing["device_id"] = device_id.strip()
                save_record("sessions", existing)
                return jsonify(session_to_dict(existing)), 201
        else:
            session_id = str(uuid.uuid4())

        ts = now_iso()
        row = {
            "id": session_id,
            "created_at": ts,
            "updated_at": ts,
            "name": session_name,
            "agent": agent.strip() if isinstance(agent, str) and agent.strip() else "iris",
            "status": SESSION_STATUS_ACTIVE,
            "device_id": device_id.strip() if isinstance(device_id, str) else None,
            "source_device_id": source_device_id.strip() if isinstance(source_device_id, str) else None,
            "last_message_at": None,
            "metadata": metadata,
        }
        save_record("sessions", row)
        return jsonify(session_to_dict(row)), 201

    @app.get("/api/sessions")
    def list_sessions() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            status_filter = parse_session_status_filter(request.args.get("status"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        sessions = list_records("sessions")
        transcripts = list_records("transcripts")
        commands = list_records("device_commands")
        statuses = list_records("agent_status")

        if status_filter:
            sessions = [row for row in sessions if row.get("status") == status_filter]

        sessions = sorted(sessions, key=lambda row: (to_dt(row.get("updated_at")), str(row.get("id", ""))), reverse=True)
        sessions = sessions[:limit]

        transcript_counts: dict[str, int] = {}
        for row in transcripts:
            sid = row.get("session_id")
            if isinstance(sid, str):
                transcript_counts[sid] = transcript_counts.get(sid, 0) + 1

        pending_counts: dict[str, int] = {}
        for row in commands:
            sid = row.get("session_id")
            status = row.get("status")
            if isinstance(sid, str) and status in {COMMAND_STATUS_QUEUED, COMMAND_STATUS_IN_PROGRESS}:
                pending_counts[sid] = pending_counts.get(sid, 0) + 1

        latest_by_session: dict[str, dict[str, Any]] = {}
        for row in statuses:
            sid = row.get("session_id")
            if not isinstance(sid, str):
                continue
            current = latest_by_session.get(sid)
            if current is None or (to_dt(row.get("updated_at")), str(row.get("id", ""))) > (
                to_dt(current.get("updated_at")),
                str(current.get("id", "")),
            ):
                latest_by_session[sid] = row

        items = []
        for row in sessions:
            base = session_to_dict(row)
            sid = str(base["id"])
            latest = latest_by_session.get(sid)
            base["transcript_count"] = transcript_counts.get(sid, 0)
            base["pending_command_count"] = pending_counts.get(sid, 0)
            base["latest_status_headline"] = latest.get("headline") if latest else None
            base["latest_status_phase"] = latest.get("phase") if latest else None
            base["latest_status_updated_at"] = latest.get("updated_at") if latest else None
            items.append(base)

        return jsonify({"items": items, "count": len(items)})

    @app.get("/api/sessions/<session_id>")
    def get_session(session_id: str) -> Any:
        session_row = get_record("sessions", session_id)
        if not session_row:
            return jsonify({"error": "session not found"}), 404

        transcripts = [row for row in list_records("transcripts") if row.get("session_id") == session_id]
        commands = [row for row in list_records("device_commands") if row.get("session_id") == session_id]
        statuses = [row for row in list_records("agent_status") if row.get("session_id") == session_id]

        latest_status = newest_record(statuses, ts_key="updated_at")

        session_dict = session_to_dict(session_row)
        session_dict["transcript_count"] = len(transcripts)
        session_dict["pending_command_count"] = len(
            [row for row in commands if row.get("status") in {COMMAND_STATUS_QUEUED, COMMAND_STATUS_IN_PROGRESS}]
        )
        session_dict["latest_status"] = agent_status_to_dict(latest_status)
        return jsonify(session_dict)

    @app.put("/api/sessions/<session_id>")
    def update_session(session_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        name = payload.get("name")
        status_raw = payload.get("status")

        if name is not None and (not isinstance(name, str) or not name.strip()):
            return jsonify({"error": "name must be a non-empty string when provided"}), 400

        status: str | None = None
        if status_raw is not None:
            try:
                status = parse_session_status(status_raw)
            except ValueError as exc:
                return jsonify({"error": str(exc)}), 400

        row = get_record("sessions", session_id)
        if not row:
            return jsonify({"error": "session not found"}), 404

        row["updated_at"] = now_iso()
        if isinstance(name, str):
            row["name"] = name.strip()
        if status is not None:
            row["status"] = status

        save_record("sessions", row)
        return jsonify(session_to_dict(row))

    @app.post("/api/transcripts")
    def create_transcript() -> Any:
        payload = request.get_json(silent=True) or {}
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return jsonify({"error": "text is required"}), 400
        if len(text.strip()) > MAX_TRANSCRIPT_CHARS:
            return jsonify({"error": f"text exceeds max length ({MAX_TRANSCRIPT_CHARS} chars)"}), 400

        try:
            session_id = parse_optional_session_id(payload.get("session_id"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        if session_id and not ensure_session_exists(session_id):
            return jsonify({"error": "session not found"}), 400

        transcript_id = str(uuid.uuid4())
        created_at = now_iso()
        captured_at_raw = payload.get("captured_at")
        captured_at = created_at
        if captured_at_raw:
            try:
                captured_at = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        row = {
            "id": transcript_id,
            "created_at": created_at,
            "updated_at": created_at,
            "captured_at": captured_at,
            "session_id": session_id,
            "device_id": payload.get("device_id"),
            "source": payload.get("source"),
            "text": text.strip(),
        }
        save_record("transcripts", row)
        touch_session(session_id)
        return jsonify(transcript_to_dict(row)), 201

    @app.get("/api/transcripts/<transcript_id>")
    def get_transcript(transcript_id: str) -> Any:
        row = get_record("transcripts", transcript_id)
        if not row:
            return jsonify({"error": "transcript not found"}), 404
        return jsonify(transcript_to_dict(row))

    @app.get("/api/transcripts")
    def list_transcripts() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(request.args.get("cursor"), request.args.get("since"))
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        session_id = (request.args.get("session_id") or "").strip() or None

        rows = list_records("transcripts")
        filtered: list[dict[str, Any]] = []
        for row in rows:
            if device_id is not None and row.get("device_id") != device_id:
                continue
            if session_id is not None and row.get("session_id") != session_id:
                continue
            captured_at = row.get("captured_at") or row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(captured_at, item_id, cursor_ts, cursor_id):
                continue
            filtered.append(row)

        filtered.sort(
            key=lambda row: (
                to_dt(row.get("captured_at") or row.get("created_at")),
                to_dt(row.get("created_at")),
                str(row.get("id", "")),
            )
        )
        filtered = filtered[:limit]

        items = [transcript_to_dict(row) for row in filtered]
        next_since = items[-1]["captured_at"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["captured_at"], items[-1]["id"]) if items else None
        return jsonify({
            "items": items,
            "count": len(items),
            "next_since": next_since,
            "next_cursor": next_cursor,
        })

    @app.put("/api/transcripts/<transcript_id>")
    def update_transcript(transcript_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return jsonify({"error": "text is required"}), 400
        if len(text.strip()) > MAX_TRANSCRIPT_CHARS:
            return jsonify({"error": f"text exceeds max length ({MAX_TRANSCRIPT_CHARS} chars)"}), 400

        row = get_record("transcripts", transcript_id)
        if not row:
            return jsonify({"error": "transcript not found"}), 404

        captured_at_raw = payload.get("captured_at")
        if captured_at_raw:
            try:
                row["captured_at"] = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        row["updated_at"] = now_iso()
        row["text"] = text.strip()
        save_record("transcripts", row)
        return jsonify(transcript_to_dict(row))

    @app.delete("/api/transcripts/<transcript_id>")
    def delete_transcript(transcript_id: str) -> Any:
        if not delete_record("transcripts", transcript_id):
            return jsonify({"error": "transcript not found"}), 404
        return jsonify({"id": transcript_id, "deleted": True})

    @app.post("/api/device-commands")
    def create_device_command() -> Any:
        payload = request.get_json(silent=True) or {}
        target_device_id = payload.get("target_device_id")
        command_type = payload.get("command_type")
        command_payload = payload.get("payload", {})
        source_device_id = payload.get("source_device_id")

        try:
            session_id = parse_optional_session_id(payload.get("session_id"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        if not isinstance(target_device_id, str) or not target_device_id.strip():
            return jsonify({"error": "target_device_id is required"}), 400
        if not isinstance(command_type, str) or not command_type.strip():
            return jsonify({"error": "command_type is required"}), 400
        if not isinstance(command_payload, dict):
            command_payload = {}

        if session_id and not ensure_session_exists(session_id):
            return jsonify({"error": "session not found"}), 400

        command_id = str(uuid.uuid4())
        ts = now_iso()
        row = {
            "id": command_id,
            "created_at": ts,
            "updated_at": ts,
            "target_device_id": target_device_id.strip(),
            "session_id": session_id,
            "source_device_id": source_device_id.strip() if isinstance(source_device_id, str) else None,
            "command_type": command_type.strip(),
            "payload": command_payload,
            "status": COMMAND_STATUS_QUEUED,
            "acknowledged_at": None,
            "completed_at": None,
            "result": None,
            "error": None,
        }
        save_record("device_commands", row)
        touch_session(session_id)
        return jsonify(command_to_dict(row)), 201

    @app.get("/api/device-commands")
    def list_device_commands() -> Any:
        target_device_id = (request.args.get("target_device_id") or "").strip()
        if not target_device_id:
            return jsonify({"error": "target_device_id query parameter is required"}), 400
        session_id = (request.args.get("session_id") or "").strip() or None

        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(request.args.get("cursor"), request.args.get("since"))
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        try:
            statuses = parse_status_list(
                request.args.get("statuses"),
                {COMMAND_STATUS_QUEUED, COMMAND_STATUS_IN_PROGRESS},
            )
        except ValueError:
            return jsonify({"error": "statuses must be comma-separated known status values"}), 400

        rows = list_records("device_commands")
        filtered: list[dict[str, Any]] = []
        for row in rows:
            if row.get("target_device_id") != target_device_id:
                continue
            if row.get("status") not in statuses:
                continue
            if session_id is not None and row.get("session_id") != session_id:
                continue
            created_at = row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(created_at, item_id, cursor_ts, cursor_id):
                continue
            filtered.append(row)

        filtered.sort(key=lambda row: (to_dt(row.get("created_at")), str(row.get("id", ""))))
        filtered = filtered[:limit]

        items = [command_to_dict(row) for row in filtered]
        next_since = items[-1]["created_at"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["created_at"], items[-1]["id"]) if items else None
        return jsonify({
            "items": items,
            "count": len(items),
            "next_since": next_since,
            "next_cursor": next_cursor,
        })

    @app.get("/api/device-commands/<command_id>")
    def get_device_command(command_id: str) -> Any:
        row = get_record("device_commands", command_id)
        if not row:
            return jsonify({"error": "device command not found"}), 404
        return jsonify(command_to_dict(row))

    @app.post("/api/device-commands/<command_id>/ack")
    def ack_device_command(command_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        status = payload.get("status")
        if status not in {
            COMMAND_STATUS_IN_PROGRESS,
            COMMAND_STATUS_COMPLETED,
            COMMAND_STATUS_FAILED,
            COMMAND_STATUS_CANCELED,
        }:
            return jsonify({"error": "status must be one of: in_progress, completed, failed, canceled"}), 400

        row = get_record("device_commands", command_id)
        if not row:
            return jsonify({"error": "device command not found"}), 404

        ts = now_iso()
        row["updated_at"] = ts
        row["status"] = status
        row["acknowledged_at"] = row.get("acknowledged_at") or ts
        row["completed_at"] = ts if status in {COMMAND_STATUS_COMPLETED, COMMAND_STATUS_FAILED, COMMAND_STATUS_CANCELED} else None

        if "result" in payload:
            row["result"] = payload.get("result")

        if "error" in payload:
            error_value = payload.get("error")
            if error_value is not None and not isinstance(error_value, str):
                return jsonify({"error": "error must be a string or null"}), 400
            row["error"] = error_value

        save_record("device_commands", row)
        touch_session(row.get("session_id"))
        return jsonify(command_to_dict(row))

    # ─── Messages ─────────────────────────────────────────────────────────

    @app.post("/api/sessions/<session_id>/messages")
    def create_message(session_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        role = payload.get("role")
        content = payload.get("content")

        if role not in ("user", "assistant"):
            return jsonify({"error": "role must be 'user' or 'assistant'"}), 400
        if not isinstance(content, str) or not content.strip():
            return jsonify({"error": "content is required"}), 400

        message_id = payload.get("id") or str(uuid.uuid4())
        ts = now_iso()
        device_id = payload.get("device_id")

        # Idempotent — skip if message already exists
        existing = get_record("messages", message_id)
        if existing:
            return jsonify(message_to_dict(existing)), 201

        # Auto-create session if it doesn't exist
        if not ensure_session_exists(session_id):
            session_ts = ts
            session_row = {
                "id": session_id,
                "created_at": session_ts,
                "updated_at": session_ts,
                "name": "Untitled",
                "agent": "iris",
                "status": SESSION_STATUS_ACTIVE,
                "device_id": None,
                "source_device_id": None,
                "last_message_at": None,
                "metadata": {},
            }
            save_record("sessions", session_row)

        row = {
            "id": message_id,
            "session_id": session_id,
            "created_at": ts,
            "role": role,
            "content": content.strip(),
            "device_id": device_id,
        }
        save_record("messages", row)

        # Update session's last_message_at
        session_row = get_record("sessions", session_id)
        if session_row:
            session_row["last_message_at"] = ts
            session_row["updated_at"] = ts
            save_record("sessions", session_row)

        return jsonify(message_to_dict(row)), 201

    @app.get("/api/sessions/<session_id>/messages")
    def list_messages(session_id: str) -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        since = None
        raw_since = request.args.get("since")
        if raw_since:
            try:
                since = parse_iso8601_to_utc(raw_since)
            except ValueError:
                return jsonify({"error": "since must be a valid ISO-8601 timestamp"}), 400

        all_messages = list_records("messages")
        filtered = [row for row in all_messages if row.get("session_id") == session_id]

        if since:
            filtered = [row for row in filtered if row.get("created_at", "") > since]

        filtered.sort(key=lambda row: (to_dt(row.get("created_at")), str(row.get("id", ""))))
        filtered = filtered[:limit]

        items = [message_to_dict(row) for row in filtered]
        return jsonify({
            "items": items,
            "count": len(items),
        })

    @app.delete("/api/sessions/<session_id>")
    def delete_session(session_id: str) -> Any:
        if not get_record("sessions", session_id):
            return jsonify({"error": "session not found"}), 404

        # Delete associated messages
        all_messages = list_records("messages")
        for msg in all_messages:
            if msg.get("session_id") == session_id:
                delete_record("messages", str(msg.get("id")))

        delete_record("sessions", session_id)
        return jsonify({"id": session_id, "deleted": True})

    @app.post("/api/agent-status")
    def upsert_agent_status() -> Any:
        payload = request.get_json(silent=True) or {}
        try:
            session_id = parse_optional_session_id(payload.get("session_id"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        phase = payload.get("phase")
        headline = payload.get("headline")
        detail = payload.get("detail")
        source_device_id = payload.get("source_device_id")
        metadata = payload.get("metadata", {})

        if not isinstance(phase, str) or not phase.strip():
            return jsonify({"error": "phase is required"}), 400
        if not isinstance(headline, str) or not headline.strip():
            return jsonify({"error": "headline is required"}), 400
        if detail is not None and not isinstance(detail, str):
            return jsonify({"error": "detail must be a string or null"}), 400
        if source_device_id is not None and not isinstance(source_device_id, str):
            return jsonify({"error": "source_device_id must be a string or null"}), 400
        if not isinstance(metadata, (dict, list)):
            metadata = {}

        if session_id and not ensure_session_exists(session_id):
            return jsonify({"error": "session not found"}), 400

        status_id = str(uuid.uuid4())
        ts = now_iso()
        row = {
            "id": status_id,
            "created_at": ts,
            "updated_at": ts,
            "session_id": session_id,
            "phase": phase.strip(),
            "headline": headline.strip(),
            "detail": detail.strip() if isinstance(detail, str) else None,
            "source_device_id": source_device_id.strip() if isinstance(source_device_id, str) else None,
            "metadata": metadata,
        }
        save_record("agent_status", row)
        touch_session(session_id)
        return jsonify(agent_status_to_dict(row)), 201

    @app.get("/api/agent-status")
    def get_agent_status() -> Any:
        session_id = (request.args.get("session_id") or "").strip() or None

        statuses = list_records("agent_status")
        commands = list_records("device_commands")
        transcripts = list_records("transcripts")
        screenshots = list_records("screenshots")

        if session_id is not None:
            statuses = [row for row in statuses if row.get("session_id") == session_id]
            commands = [row for row in commands if row.get("session_id") == session_id]
            transcripts = [row for row in transcripts if row.get("session_id") == session_id]
            screenshots = [row for row in screenshots if row.get("session_id") == session_id]

        latest = newest_record(statuses, ts_key="updated_at")

        command_counts = {status: 0 for status in sorted(COMMAND_STATUSES)}
        pending_device_counts: dict[str, int] = {}
        for row in commands:
            status = row.get("status")
            if status in command_counts:
                command_counts[status] += 1
            if status in {COMMAND_STATUS_QUEUED, COMMAND_STATUS_IN_PROGRESS}:
                target = row.get("target_device_id")
                if isinstance(target, str):
                    pending_device_counts[target] = pending_device_counts.get(target, 0) + 1

        pending_devices = [
            {"target_device_id": key, "count": value}
            for key, value in sorted(pending_device_counts.items(), key=lambda pair: (-pair[1], pair[0]))
        ]

        last_transcript = newest_record(transcripts, ts_key="captured_at")
        for row in screenshots:
            row["_sort_ts"] = row.get("captured_at") or row.get("created_at")
        last_screenshot = newest_record(screenshots, ts_key="_sort_ts")

        recent_inputs = {
            "last_transcript": (
                {
                    "id": last_transcript.get("id"),
                    "device_id": last_transcript.get("device_id"),
                    "ts": last_transcript.get("captured_at") or last_transcript.get("created_at"),
                }
                if last_transcript
                else None
            ),
            "last_screenshot": (
                {
                    "id": last_screenshot.get("id"),
                    "device_id": last_screenshot.get("device_id"),
                    "ts": last_screenshot.get("captured_at") or last_screenshot.get("created_at"),
                }
                if last_screenshot
                else None
            ),
        }

        return jsonify({
            "session_id": session_id,
            "status": agent_status_to_dict(latest),
            "command_counts": command_counts,
            "pending_by_device": pending_devices,
            "recent_inputs": recent_inputs,
            "server_ts": now_iso(),
        })

    @app.get("/api/events")
    def list_events() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(request.args.get("cursor"), request.args.get("since"))
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        session_id = (request.args.get("session_id") or "").strip() or None
        event_type = request.args.get("event_type")
        if event_type and event_type not in {"transcript", "screenshot"}:
            return jsonify({"error": "event_type must be one of: transcript, screenshot"}), 400

        events: list[dict[str, Any]] = []
        if event_type in {None, "transcript"}:
            for row in list_records("transcripts"):
                events.append({
                    "event_type": "transcript",
                    "id": row.get("id"),
                    "created_at": row.get("created_at"),
                    "updated_at": row.get("updated_at"),
                    "captured_at": row.get("captured_at"),
                    "session_id": row.get("session_id"),
                    "device_id": row.get("device_id"),
                    "source": row.get("source"),
                    "text": row.get("text"),
                    "mime_type": None,
                    "file_path": None,
                    "notes": None,
                    "sort_ts": row.get("captured_at") or row.get("created_at"),
                })

        if event_type in {None, "screenshot"}:
            for row in list_records("screenshots"):
                events.append({
                    "event_type": "screenshot",
                    "id": row.get("id"),
                    "created_at": row.get("created_at"),
                    "updated_at": row.get("updated_at"),
                    "captured_at": row.get("captured_at"),
                    "session_id": row.get("session_id"),
                    "device_id": row.get("device_id"),
                    "source": row.get("source"),
                    "text": None,
                    "mime_type": row.get("mime_type"),
                    "file_path": row.get("file_path"),
                    "notes": row.get("notes"),
                    "sort_ts": row.get("captured_at") or row.get("created_at"),
                })

        filtered: list[dict[str, Any]] = []
        for row in events:
            if device_id is not None and row.get("device_id") != device_id:
                continue
            if session_id is not None and row.get("session_id") != session_id:
                continue
            sort_ts = row.get("sort_ts") or row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(sort_ts, item_id, cursor_ts, cursor_id):
                continue
            filtered.append(row)

        filtered.sort(
            key=lambda row: (
                to_dt(row.get("sort_ts")),
                to_dt(row.get("created_at")),
                str(row.get("id", "")),
            )
        )
        filtered = filtered[:limit]

        items = [
            {
                "event_type": row["event_type"],
                "id": row["id"],
                "event_ts": row["sort_ts"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "captured_at": row["captured_at"],
                "session_id": row["session_id"],
                "device_id": row["device_id"],
                "source": row["source"],
                "text": row["text"],
                "mime_type": row["mime_type"],
                "file_path": row["file_path"],
                "file_url": (
                    url_for("get_screenshot_file", screenshot_id=row["id"], _external=True)
                    if row["event_type"] == "screenshot"
                    else None
                ),
                "notes": row["notes"],
            }
            for row in filtered
        ]

        next_since = items[-1]["event_ts"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["event_ts"], items[-1]["id"]) if items else None
        return jsonify({
            "items": items,
            "count": len(items),
            "next_since": next_since,
            "next_cursor": next_cursor,
        })

    @app.post("/api/screenshots")
    def upload_screenshot() -> Any:
        if "screenshot" not in request.files:
            return jsonify({"error": "multipart form-data with screenshot file is required"}), 400

        shot = request.files["screenshot"]
        if not shot.filename:
            return jsonify({"error": "screenshot filename is empty"}), 400

        screenshot_id = str(uuid.uuid4())
        created_at = now_iso()
        device_id_raw = request.form.get("device_id")
        source = request.form.get("source")
        notes = request.form.get("notes")
        session_id_raw = request.form.get("session_id")
        captured_at_raw = request.form.get("captured_at")
        mime_type = shot.content_type or ""

        if not mime_type.startswith(ALLOWED_SCREENSHOT_MIME_PREFIX):
            return jsonify({"error": "screenshot must be an image MIME type"}), 400

        try:
            session_id = parse_optional_session_id(session_id_raw)
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        if session_id and not ensure_session_exists(session_id):
            return jsonify({"error": "session not found"}), 400

        captured_at = created_at
        if captured_at_raw:
            try:
                captured_at = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        device_id = normalize_screenshot_device_id(device_id_raw, source)

        safe_name = secure_filename(shot.filename)
        ext = Path(safe_name).suffix or ".png"
        device_dir = screenshot_device_dir(device_id)
        device_dir.mkdir(parents=True, exist_ok=True)
        file_path = device_dir / f"{screenshot_id}{ext}"
        shot.save(file_path)

        row = {
            "id": screenshot_id,
            "created_at": created_at,
            "updated_at": created_at,
            "captured_at": captured_at,
            "session_id": session_id,
            "device_id": device_id,
            "source": source,
            "mime_type": mime_type,
            "file_path": str(file_path),
            "notes": notes,
        }
        save_record("screenshots", row)
        touch_session(session_id)
        return jsonify(screenshot_to_dict(row)), 201

    @app.get("/api/screenshots")
    def list_screenshots() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(request.args.get("cursor"), request.args.get("since"))
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        session_id = (request.args.get("session_id") or "").strip() or None

        rows = list_records("screenshots")
        filtered: list[dict[str, Any]] = []
        for row in rows:
            if device_id is not None and row.get("device_id") != device_id:
                continue
            if session_id is not None and row.get("session_id") != session_id:
                continue
            sort_ts = row.get("captured_at") or row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(sort_ts, item_id, cursor_ts, cursor_id):
                continue
            filtered.append(row)

        filtered.sort(
            key=lambda row: (
                to_dt(row.get("captured_at") or row.get("created_at")),
                to_dt(row.get("created_at")),
                str(row.get("id", "")),
            )
        )
        filtered = filtered[:limit]

        items = [screenshot_to_dict(row) for row in filtered]
        next_ts = (items[-1]["captured_at"] or items[-1]["created_at"]) if items else cursor_ts
        next_cursor = make_cursor(next_ts, items[-1]["id"]) if items else None
        return jsonify({
            "items": items,
            "count": len(items),
            "next_since": next_ts,
            "next_cursor": next_cursor,
        })

    @app.get("/api/screenshots/<screenshot_id>")
    def get_screenshot_meta(screenshot_id: str) -> Any:
        row = get_record("screenshots", screenshot_id)
        if not row:
            return jsonify({"error": "screenshot not found"}), 404
        return jsonify(screenshot_to_dict(row))

    @app.get("/api/screenshots/<screenshot_id>/file")
    def get_screenshot_file(screenshot_id: str) -> Any:
        row = get_record("screenshots", screenshot_id)
        if not row:
            return jsonify({"error": "screenshot not found"}), 404

        file_path = Path(str(row.get("file_path") or ""))
        if not file_path.exists():
            return jsonify({"error": "screenshot file missing"}), 410
        mimetype = row.get("mime_type") or "application/octet-stream"
        return send_file(file_path, mimetype=mimetype)

    @app.delete("/api/screenshots/<screenshot_id>")
    def delete_screenshot(screenshot_id: str) -> Any:
        row = get_record("screenshots", screenshot_id)
        if not row:
            return jsonify({"error": "screenshot not found"}), 404

        delete_record("screenshots", screenshot_id)
        file_path = Path(str(row.get("file_path") or ""))
        file_stats = delete_files([file_path])
        return jsonify({
            "id": screenshot_id,
            "deleted": True,
            "files_removed": file_stats["removed"],
            "files_missing": file_stats["missing"],
            "files_failed": file_stats["failed"],
        })

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=True)

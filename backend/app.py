from __future__ import annotations

import json
import os
import sqlite3
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
SCREENSHOTS_DIR = DATA_DIR / "screenshots"
DB_PATH = DATA_DIR / "iris.db"
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


RATE_LIMIT_STATE: dict[str, list[float]] = {}
RATE_LIMIT_LOCK = threading.Lock()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dirs() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    SCREENSHOTS_DIR.mkdir(exist_ok=True)


def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def ensure_column(conn: sqlite3.Connection, table: str, column: str, ddl: str) -> None:
    columns = conn.execute(f"PRAGMA table_info({table})").fetchall()
    column_names = {col["name"] for col in columns}
    if column not in column_names:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")


def init_db() -> None:
    with db_connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS transcripts (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                device_id TEXT,
                source TEXT,
                text TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS screenshots (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                captured_at TEXT,
                device_id TEXT,
                session_id TEXT,
                source TEXT,
                mime_type TEXT,
                file_path TEXT NOT NULL,
                notes TEXT
            );

            CREATE TABLE IF NOT EXISTS device_commands (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                target_device_id TEXT NOT NULL,
                source_device_id TEXT,
                command_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                status TEXT NOT NULL,
                acknowledged_at TEXT,
                completed_at TEXT,
                result_json TEXT,
                error_text TEXT
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                name TEXT NOT NULL DEFAULT 'Untitled',
                agent TEXT NOT NULL DEFAULT 'iris',
                device_id TEXT,
                last_message_at TEXT
            );

            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                device_id TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );
            """
        )
        ensure_column(conn, "screenshots", "captured_at", "TEXT")
        ensure_column(conn, "screenshots", "session_id", "TEXT")


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


def transcript_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "captured_at": row["captured_at"],
        "device_id": row["device_id"],
        "source": row["source"],
        "text": row["text"],
    }


def screenshot_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    file_url = url_for("get_screenshot_file", screenshot_id=row["id"], _external=True)
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "captured_at": row["captured_at"],
        "device_id": row["device_id"],
        "session_id": row["session_id"],
        "source": row["source"],
        "mime_type": row["mime_type"],
        "file_path": row["file_path"],
        "file_url": file_url,
        "notes": row["notes"],
    }


def parse_json_field(raw: str | None, default: Any) -> Any:
    if raw is None:
        return default
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return default


def command_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "target_device_id": row["target_device_id"],
        "source_device_id": row["source_device_id"],
        "command_type": row["command_type"],
        "payload": parse_json_field(row["payload_json"], {}),
        "status": row["status"],
        "acknowledged_at": row["acknowledged_at"],
        "completed_at": row["completed_at"],
        "result": parse_json_field(row["result_json"], None),
        "error": row["error_text"],
    }


def session_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "name": row["name"],
        "agent": row["agent"],
        "device_id": row["device_id"],
        "last_message_at": row["last_message_at"],
    }


def message_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "session_id": row["session_id"],
        "created_at": row["created_at"],
        "role": row["role"],
        "content": row["content"],
        "device_id": row["device_id"],
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


def create_app() -> Flask:
    ensure_dirs()
    init_db()

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
                jsonify(
                    {
                        "error": "rate limit exceeded",
                        "retry_after_seconds": retry_after,
                    }
                ),
                429,
                {"Retry-After": str(retry_after)},
            )
        return None

    @app.errorhandler(RequestEntityTooLarge)
    def handle_request_too_large(_: RequestEntityTooLarge) -> Any:
        return (
            jsonify(
                {
                    "error": "request too large",
                    "max_bytes": MAX_REQUEST_BYTES,
                }
            ),
            413,
        )

    @app.get("/health")
    def health() -> Any:
        return jsonify({"status": "ok", "ts": now_iso()})

    @app.post("/api/transcripts")
    def create_transcript() -> Any:
        payload = request.get_json(silent=True) or {}
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return jsonify({"error": "text is required"}), 400
        if len(text.strip()) > MAX_TRANSCRIPT_CHARS:
            return jsonify({"error": f"text exceeds max length ({MAX_TRANSCRIPT_CHARS} chars)"}), 400

        transcript_id = str(uuid.uuid4())
        created_at = now_iso()
        captured_at_raw = payload.get("captured_at")
        captured_at = created_at
        if captured_at_raw:
            try:
                captured_at = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        device_id = payload.get("device_id")
        source = payload.get("source")

        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO transcripts (
                    id, created_at, updated_at, captured_at, device_id, source, text
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    transcript_id,
                    created_at,
                    created_at,
                    captured_at,
                    device_id,
                    source,
                    text.strip(),
                ),
            )
            row = conn.execute(
                "SELECT * FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
        return jsonify(transcript_to_dict(row)), 201

    @app.get("/api/transcripts/<transcript_id>")
    def get_transcript(transcript_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
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
            cursor_ts, cursor_id = parse_paging_cursor(
                request.args.get("cursor"),
                request.args.get("since"),
            )
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        with db_connect() as conn:
            rows = conn.execute(
                """
                SELECT *
                FROM transcripts
                WHERE (
                      ? IS NULL
                   OR captured_at > ?
                   OR (captured_at = ? AND id > ?)
                )
                  AND (? IS NULL OR device_id = ?)
                ORDER BY captured_at ASC, created_at ASC, id ASC
                LIMIT ?
                """,
                (
                    cursor_ts,
                    cursor_ts,
                    cursor_ts,
                    cursor_id,
                    device_id,
                    device_id,
                    limit,
                ),
            ).fetchall()

        items = [transcript_to_dict(row) for row in rows]
        next_since = items[-1]["captured_at"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["captured_at"], items[-1]["id"]) if items else None
        return jsonify(
            {
                "items": items,
                "count": len(items),
                "next_since": next_since,
                "next_cursor": next_cursor,
            }
        )

    @app.put("/api/transcripts/<transcript_id>")
    def update_transcript(transcript_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return jsonify({"error": "text is required"}), 400
        if len(text.strip()) > MAX_TRANSCRIPT_CHARS:
            return jsonify({"error": f"text exceeds max length ({MAX_TRANSCRIPT_CHARS} chars)"}), 400

        ts = now_iso()
        captured_at_raw = payload.get("captured_at")
        captured_at: str | None = None
        if captured_at_raw:
            try:
                captured_at = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
            if not row:
                return jsonify({"error": "transcript not found"}), 404

            conn.execute(
                """
                UPDATE transcripts
                SET updated_at = ?, text = ?, captured_at = COALESCE(?, captured_at)
                WHERE id = ?
                """,
                (ts, text.strip(), captured_at, transcript_id),
            )
            row = conn.execute(
                "SELECT * FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
        return jsonify(transcript_to_dict(row))

    @app.delete("/api/transcripts/<transcript_id>")
    def delete_transcript(transcript_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT id FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
            if not row:
                return jsonify({"error": "transcript not found"}), 404
            conn.execute("DELETE FROM transcripts WHERE id = ?", (transcript_id,))
        return jsonify({"id": transcript_id, "deleted": True})

    @app.post("/api/device-commands")
    def create_device_command() -> Any:
        payload = request.get_json(silent=True) or {}
        target_device_id = payload.get("target_device_id")
        command_type = payload.get("command_type")
        command_payload = payload.get("payload", {})
        source_device_id = payload.get("source_device_id")

        if not isinstance(target_device_id, str) or not target_device_id.strip():
            return jsonify({"error": "target_device_id is required"}), 400
        if not isinstance(command_type, str) or not command_type.strip():
            return jsonify({"error": "command_type is required"}), 400

        command_id = str(uuid.uuid4())
        ts = now_iso()
        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO device_commands (
                    id,
                    created_at,
                    updated_at,
                    target_device_id,
                    source_device_id,
                    command_type,
                    payload_json,
                    status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    command_id,
                    ts,
                    ts,
                    target_device_id.strip(),
                    source_device_id.strip() if isinstance(source_device_id, str) else None,
                    command_type.strip(),
                    json.dumps(command_payload),
                    COMMAND_STATUS_QUEUED,
                ),
            )
            row = conn.execute(
                "SELECT * FROM device_commands WHERE id = ?",
                (command_id,),
            ).fetchone()
        return jsonify(command_to_dict(row)), 201

    @app.get("/api/device-commands")
    def list_device_commands() -> Any:
        target_device_id = (request.args.get("target_device_id") or "").strip()
        if not target_device_id:
            return jsonify({"error": "target_device_id query parameter is required"}), 400

        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(
                request.args.get("cursor"),
                request.args.get("since"),
            )
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        try:
            statuses = parse_status_list(
                request.args.get("statuses"),
                {COMMAND_STATUS_QUEUED, COMMAND_STATUS_IN_PROGRESS},
            )
        except ValueError:
            return jsonify({"error": "statuses must be comma-separated known status values"}), 400

        status_placeholders = ",".join("?" for _ in statuses)
        query = f"""
            SELECT *
            FROM device_commands
            WHERE target_device_id = ?
              AND status IN ({status_placeholders})
              AND (
                    ? IS NULL
                 OR created_at > ?
                 OR (created_at = ? AND id > ?)
              )
            ORDER BY created_at ASC, id ASC
            LIMIT ?
        """
        params: list[Any] = [target_device_id, *statuses, cursor_ts, cursor_ts, cursor_ts, cursor_id, limit]
        with db_connect() as conn:
            rows = conn.execute(query, params).fetchall()

        items = [command_to_dict(row) for row in rows]
        next_since = items[-1]["created_at"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["created_at"], items[-1]["id"]) if items else None
        return jsonify(
            {
                "items": items,
                "count": len(items),
                "next_since": next_since,
                "next_cursor": next_cursor,
            }
        )

    @app.get("/api/device-commands/<command_id>")
    def get_device_command(command_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM device_commands WHERE id = ?",
                (command_id,),
            ).fetchone()
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

        ts = now_iso()
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM device_commands WHERE id = ?",
                (command_id,),
            ).fetchone()
            if not row:
                return jsonify({"error": "device command not found"}), 404

            acknowledged_at = row["acknowledged_at"] or ts
            completed_at = ts if status in {COMMAND_STATUS_COMPLETED, COMMAND_STATUS_FAILED, COMMAND_STATUS_CANCELED} else None

            result_json = row["result_json"]
            if "result" in payload:
                result_json = json.dumps(payload.get("result"))

            error_text = row["error_text"]
            if "error" in payload:
                error_value = payload.get("error")
                if error_value is not None and not isinstance(error_value, str):
                    return jsonify({"error": "error must be a string or null"}), 400
                error_text = error_value

            conn.execute(
                """
                UPDATE device_commands
                SET updated_at = ?,
                    status = ?,
                    acknowledged_at = ?,
                    completed_at = ?,
                    result_json = ?,
                    error_text = ?
                WHERE id = ?
                """,
                (
                    ts,
                    status,
                    acknowledged_at,
                    completed_at,
                    result_json,
                    error_text,
                    command_id,
                ),
            )
            row = conn.execute(
                "SELECT * FROM device_commands WHERE id = ?",
                (command_id,),
            ).fetchone()

        return jsonify(command_to_dict(row))

    # ─── Sessions ──────────────────────────────────────────────────────────

    @app.post("/api/sessions")
    def create_session() -> Any:
        payload = request.get_json(silent=True) or {}
        session_id = payload.get("id")
        if not isinstance(session_id, str) or not session_id.strip():
            return jsonify({"error": "id is required"}), 400

        session_id = session_id.strip()
        ts = now_iso()
        name = payload.get("name", "Untitled") or "Untitled"
        agent = payload.get("agent", "iris") or "iris"
        device_id = payload.get("device_id")

        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO sessions (id, created_at, updated_at, name, agent, device_id, last_message_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    updated_at = excluded.updated_at,
                    name = COALESCE(excluded.name, sessions.name),
                    agent = COALESCE(excluded.agent, sessions.agent),
                    device_id = COALESCE(excluded.device_id, sessions.device_id)
                """,
                (session_id, ts, ts, name, agent, device_id),
            )
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        return jsonify(session_to_dict(row)), 201

    @app.get("/api/sessions")
    def list_sessions() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        with db_connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM sessions
                ORDER BY COALESCE(last_message_at, updated_at) DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()

        return jsonify({
            "items": [session_to_dict(row) for row in rows],
            "count": len(rows),
        })

    @app.get("/api/sessions/<session_id>")
    def get_session(session_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        if not row:
            return jsonify({"error": "session not found"}), 404
        return jsonify(session_to_dict(row))

    @app.delete("/api/sessions/<session_id>")
    def delete_session(session_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute("SELECT id FROM sessions WHERE id = ?", (session_id,)).fetchone()
            if not row:
                return jsonify({"error": "session not found"}), 404
            conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
            conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
        return jsonify({"id": session_id, "deleted": True})

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

        with db_connect() as conn:
            # Ensure session exists (auto-create if not)
            existing = conn.execute("SELECT id FROM sessions WHERE id = ?", (session_id,)).fetchone()
            if not existing:
                conn.execute(
                    "INSERT INTO sessions (id, created_at, updated_at, name, agent) VALUES (?, ?, ?, 'Untitled', 'iris')",
                    (session_id, ts, ts),
                )

            conn.execute(
                """
                INSERT INTO messages (id, session_id, created_at, role, content, device_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                (message_id, session_id, ts, role, content.strip(), device_id),
            )
            conn.execute(
                "UPDATE sessions SET last_message_at = ?, updated_at = ? WHERE id = ?",
                (ts, ts, session_id),
            )
            row = conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
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

        with db_connect() as conn:
            if since:
                rows = conn.execute(
                    """
                    SELECT * FROM messages
                    WHERE session_id = ? AND created_at > ?
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                    (session_id, since, limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM messages
                    WHERE session_id = ?
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                    (session_id, limit),
                ).fetchall()

        items = [message_to_dict(row) for row in rows]
        return jsonify({
            "items": items,
            "count": len(items),
        })

    @app.get("/api/events")
    def list_events() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(
                request.args.get("cursor"),
                request.args.get("since"),
            )
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        event_type = request.args.get("event_type")
        if event_type and event_type not in {"transcript", "screenshot"}:
            return jsonify({"error": "event_type must be one of: transcript, screenshot"}), 400

        with db_connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    e.event_type,
                    e.id,
                    e.created_at,
                    e.updated_at,
                    e.captured_at,
                    e.device_id,
                    e.source,
                    e.text,
                    e.mime_type,
                    e.file_path,
                    e.notes,
                    e.sort_ts
                FROM (
                    SELECT
                        'transcript' AS event_type,
                        id,
                        created_at,
                        updated_at,
                        captured_at,
                        device_id,
                        source,
                        text,
                        NULL AS mime_type,
                        NULL AS file_path,
                        NULL AS notes,
                        captured_at AS sort_ts
                    FROM transcripts
                    UNION ALL
                    SELECT
                        'screenshot' AS event_type,
                        id,
                        created_at,
                        updated_at,
                        captured_at,
                        device_id,
                        source,
                        NULL AS text,
                        mime_type,
                        file_path,
                        notes,
                        COALESCE(captured_at, created_at) AS sort_ts
                    FROM screenshots
                ) AS e
                WHERE (
                      ? IS NULL
                   OR e.sort_ts > ?
                   OR (e.sort_ts = ? AND e.id > ?)
                )
                  AND (? IS NULL OR e.device_id = ?)
                  AND (? IS NULL OR e.event_type = ?)
                ORDER BY e.sort_ts ASC, e.created_at ASC, e.id ASC
                LIMIT ?
                """,
                (
                    cursor_ts,
                    cursor_ts,
                    cursor_ts,
                    cursor_id,
                    device_id,
                    device_id,
                    event_type,
                    event_type,
                    limit,
                ),
            ).fetchall()

        items = [
            {
                "event_type": row["event_type"],
                "id": row["id"],
                "event_ts": row["sort_ts"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "captured_at": row["captured_at"],
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
            for row in rows
        ]
        next_since = items[-1]["event_ts"] if items else cursor_ts
        next_cursor = make_cursor(items[-1]["event_ts"], items[-1]["id"]) if items else None
        return jsonify(
            {
                "items": items,
                "count": len(items),
                "next_since": next_since,
                "next_cursor": next_cursor,
            }
        )

    @app.post("/api/screenshots")
    def upload_screenshot() -> Any:
        if "screenshot" not in request.files:
            return jsonify({"error": "multipart form-data with screenshot file is required"}), 400

        shot = request.files["screenshot"]
        if not shot.filename:
            return jsonify({"error": "screenshot filename is empty"}), 400

        screenshot_id = str(uuid.uuid4())
        created_at = now_iso()
        device_id = request.form.get("device_id")
        session_id = request.form.get("session_id")
        source = request.form.get("source")
        notes = request.form.get("notes")
        captured_at_raw = request.form.get("captured_at")
        mime_type = shot.content_type or ""
        if not mime_type.startswith(ALLOWED_SCREENSHOT_MIME_PREFIX):
            return jsonify({"error": "screenshot must be an image MIME type"}), 400

        captured_at = created_at
        if captured_at_raw:
            try:
                captured_at = parse_iso8601_to_utc(captured_at_raw)
            except ValueError:
                return jsonify({"error": "captured_at must be a valid ISO-8601 timestamp"}), 400

        safe_name = secure_filename(shot.filename)
        ext = Path(safe_name).suffix or ".png"
        device_dir = screenshot_device_dir(device_id)
        device_dir.mkdir(parents=True, exist_ok=True)
        file_path = device_dir / f"{screenshot_id}{ext}"
        shot.save(file_path)

        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO screenshots (
                    id, created_at, updated_at, captured_at, device_id, session_id,
                    source, mime_type, file_path, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    screenshot_id,
                    created_at,
                    created_at,
                    captured_at,
                    device_id,
                    session_id,
                    source,
                    mime_type,
                    str(file_path),
                    notes,
                ),
            )
            row = conn.execute(
                "SELECT * FROM screenshots WHERE id = ?", (screenshot_id,)
            ).fetchone()

        return jsonify(screenshot_to_dict(row)), 201

    @app.get("/api/screenshots")
    def list_screenshots() -> Any:
        session_id = request.args.get("session_id")
        if session_id:
            with db_connect() as conn:
                rows = conn.execute(
                    "SELECT * FROM screenshots WHERE session_id = ? ORDER BY created_at DESC",
                    (session_id,),
                ).fetchall()
            return jsonify([screenshot_to_dict(r) for r in rows])

        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(
                request.args.get("cursor"),
                request.args.get("since"),
            )
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        device_id = request.args.get("device_id")
        with db_connect() as conn:
            rows = conn.execute(
                """
                SELECT *
                FROM screenshots
                WHERE (
                      ? IS NULL
                   OR COALESCE(captured_at, created_at) > ?
                   OR (COALESCE(captured_at, created_at) = ? AND id > ?)
                )
                  AND (? IS NULL OR device_id = ?)
                ORDER BY COALESCE(captured_at, created_at) ASC, created_at ASC, id ASC
                LIMIT ?
                """,
                (
                    cursor_ts,
                    cursor_ts,
                    cursor_ts,
                    cursor_id,
                    device_id,
                    device_id,
                    limit,
                ),
            ).fetchall()

        items = [screenshot_to_dict(row) for row in rows]
        next_ts = (items[-1]["captured_at"] or items[-1]["created_at"]) if items else cursor_ts
        next_cursor = make_cursor(next_ts, items[-1]["id"]) if items else None
        return jsonify(
            {
                "items": items,
                "count": len(items),
                "next_since": next_ts,
                "next_cursor": next_cursor,
            }
        )

    @app.get("/api/screenshots/<screenshot_id>")
    def get_screenshot_meta(screenshot_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM screenshots WHERE id = ?", (screenshot_id,)
            ).fetchone()
        if not row:
            return jsonify({"error": "screenshot not found"}), 404
        return jsonify(screenshot_to_dict(row))

    @app.get("/api/screenshots/<screenshot_id>/file")
    def get_screenshot_file(screenshot_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM screenshots WHERE id = ?", (screenshot_id,)
            ).fetchone()
        if not row:
            return jsonify({"error": "screenshot not found"}), 404

        file_path = Path(row["file_path"])
        if not file_path.exists():
            return jsonify({"error": "screenshot file missing"}), 410
        mimetype = row["mime_type"] or "application/octet-stream"
        return send_file(file_path, mimetype=mimetype)

    @app.delete("/api/screenshots/<screenshot_id>")
    def delete_screenshot(screenshot_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM screenshots WHERE id = ?", (screenshot_id,)
            ).fetchone()
            if not row:
                return jsonify({"error": "screenshot not found"}), 404
            conn.execute("DELETE FROM screenshots WHERE id = ?", (screenshot_id,))

        file_stats = delete_files([Path(row["file_path"])])
        return jsonify(
            {
                "id": screenshot_id,
                "deleted": True,
                "files_removed": file_stats["removed"],
                "files_missing": file_stats["missing"],
                "files_failed": file_stats["failed"],
            }
        )

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=True)

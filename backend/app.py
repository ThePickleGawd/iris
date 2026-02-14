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

import agent as agent_module
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


# ---------------------------------------------------------------------------
# Screenshot storage helpers (kept simple — separate files)
# ---------------------------------------------------------------------------
SCREENSHOTS_META_DIR = DATA_DIR / "screenshot_meta"
SCREENSHOTS_META_DIR.mkdir(parents=True, exist_ok=True)


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


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 15 * 1024 * 1024


    def is_cors_path(path: str) -> bool:
        return path.startswith("/api/") or path.startswith("/v1/") or path.startswith("/sessions")

    @app.after_request
    def apply_cors_headers(response: Any) -> Any:
        if is_cors_path(request.path):
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
        if not is_cors_path(request.path):
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


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> Any:
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

    # Legacy compatibility for the Mac app transport.
    @app.get("/sessions")
    def legacy_list_sessions() -> Any:
        return list_sessions()

    # Legacy compatibility for the Mac app transport.
    @app.post("/sessions")
    def legacy_create_session() -> Any:
        payload = request.get_json(silent=True) or {}
        provided_id = payload.get("id")
        name = payload.get("name")
        model = payload.get("model") or payload.get("agent")
        metadata = payload.get("metadata", {})

        if provided_id is not None and (not isinstance(provided_id, str) or not provided_id.strip()):
            return jsonify({"error": "id must be a non-empty string when provided"}), 400
        if name is not None and (not isinstance(name, str) or not name.strip()):
            return jsonify({"error": "name must be a non-empty string when provided"}), 400
        if model is not None and (not isinstance(model, str) or not model.strip()):
            return jsonify({"error": "model must be a non-empty string when provided"}), 400
        if not isinstance(metadata, (dict, list)):
            metadata = {}

        session_id = provided_id.strip() if isinstance(provided_id, str) else str(uuid.uuid4())
        existing = get_record("sessions", session_id)
        if existing:
            out = session_to_dict(existing)
            out["model"] = existing.get("model") or "gpt-5.2"
            out["agent"] = out["model"]
            return jsonify(out)

        ts = now_iso()
        row = {
            "id": session_id,
            "created_at": ts,
            "updated_at": ts,
            "name": name.strip() if isinstance(name, str) and name.strip() else "Untitled Session",
            "status": SESSION_STATUS_ACTIVE,
            "source_device_id": None,
            "metadata": metadata,
            "model": model.strip() if isinstance(model, str) and model.strip() else "gpt-5.2",
        }
        save_record("sessions", row)
        out = session_to_dict(row)
        out["model"] = row["model"]
        out["agent"] = row["model"]
        return jsonify(out), 201

    @app.post("/api/sessions")
    def create_session() -> Any:
        payload = request.get_json(silent=True) or {}
        name = payload.get("name")
        source_device_id = payload.get("source_device_id")
        metadata = payload.get("metadata", {})

        session_name = "Untitled Session"
        if isinstance(name, str) and name.strip():
            session_name = name.strip()

        if not isinstance(metadata, (dict, list)):
            metadata = {}

        session_id = str(uuid.uuid4())
        ts = now_iso()
        row = {
            "id": session_id,
            "created_at": ts,
            "updated_at": ts,
            "name": session_name,
            "status": SESSION_STATUS_ACTIVE,
            "source_device_id": source_device_id.strip() if isinstance(source_device_id, str) else None,
            "metadata": metadata,
        }
        save_record("sessions", row)
        return jsonify(session_to_dict(row)), 201

@app.get("/api/sessions")
@app.get("/sessions")
def list_sessions() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = [_session_summary(s) for s in _list_sessions()]
    rows.sort(key=lambda r: r.get("updated_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


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

    # Legacy compatibility for the Mac app transport.
    @app.delete("/sessions/<session_id>")
    def legacy_delete_session(session_id: str) -> Any:
        session_row = get_record("sessions", session_id)
        if not session_row:
            return jsonify({"error": "session not found"}), 404

        screenshot_files: list[Path] = []
        for row in list_records("screenshots"):
            if row.get("session_id") != session_id:
                continue
            file_path = Path(str(row.get("file_path") or ""))
            if str(file_path):
                screenshot_files.append(file_path)
            delete_record("screenshots", str(row.get("id")))

        for entity in ("transcripts", "device_commands", "agent_status"):
            for row in list_records(entity):
                if row.get("session_id") == session_id:
                    delete_record(entity, str(row.get("id")))

        delete_record("sessions", session_id)
        file_stats = delete_files(screenshot_files)
        return jsonify({
            "id": session_id,
            "deleted": True,
            "files_removed": file_stats["removed"],
            "files_missing": file_stats["missing"],
            "files_failed": file_stats["failed"],
        })

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

    @app.get("/api/agent-chat")
    def list_agent_chat() -> Any:
        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        try:
            cursor_ts, cursor_id = parse_paging_cursor(request.args.get("cursor"), request.args.get("since"))
        except ValueError:
            return jsonify({"error": "cursor/since must be a valid value"}), 400

        session_id = (request.args.get("session_id") or "").strip() or None

        entries: list[dict[str, Any]] = []

        for row in list_records("transcripts"):
            if session_id is not None and row.get("session_id") != session_id:
                continue
            sort_ts = row.get("captured_at") or row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(sort_ts, item_id, cursor_ts, cursor_id):
                continue
            text = row.get("text")
            if not isinstance(text, str) or not text.strip():
                continue
            entries.append({
                "id": row.get("id"),
                "entry_type": "transcript",
                "role": "user",
                "event_ts": sort_ts,
                "created_at": row.get("created_at"),
                "updated_at": row.get("updated_at"),
                "session_id": row.get("session_id"),
                "source_device_id": row.get("device_id"),
                "source": row.get("source"),
                "text": text.strip(),
            })

        for row in list_records("agent_status"):
            if session_id is not None and row.get("session_id") != session_id:
                continue
            sort_ts = row.get("updated_at") or row.get("created_at") or now_iso()
            item_id = str(row.get("id", ""))
            if not cursor_allows(sort_ts, item_id, cursor_ts, cursor_id):
                continue
            text = make_agent_chat_text(row.get("headline"), row.get("detail"))
            if not text:
                continue
            entries.append({
                "id": row.get("id"),
                "entry_type": "agent_status",
                "role": "assistant",
                "event_ts": sort_ts,
                "created_at": row.get("created_at"),
                "updated_at": row.get("updated_at"),
                "session_id": row.get("session_id"),
                "source_device_id": row.get("source_device_id"),
                "source": "agent",
                "text": text,
            })

        entries.sort(
            key=lambda row: (
                to_dt(row.get("event_ts")),
                to_dt(row.get("created_at")),
                str(row.get("id", "")),
            )
        )
        if cursor_ts is None:
            entries = entries[-limit:]
        else:
            entries = entries[:limit]

        next_since = entries[-1]["event_ts"] if entries else cursor_ts
        next_cursor = make_cursor(next_since, str(entries[-1]["id"])) if entries and next_since else None
        return jsonify({
            "items": entries,
            "count": len(entries),
            "next_since": next_since,
            "next_cursor": next_cursor,
        })

    # Legacy compatibility for the Mac app transport.
    @app.get("/sessions/<session_id>/messages")
    def legacy_session_messages(session_id: str) -> Any:
        session_row = get_record("sessions", session_id)
        if not session_row:
            return jsonify({"items": [], "count": 0})

        try:
            limit = parse_list_limit(request.args.get("limit"))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        since = request.args.get("since")
        since_dt = to_dt(parse_iso8601_to_utc(since)) if since and since.strip() else None
        items: list[dict[str, Any]] = []

        for row in list_records("transcripts"):
            if row.get("session_id") != session_id:
                continue
            created_at = row.get("created_at") or row.get("captured_at") or now_iso()
            if since_dt is not None and to_dt(created_at) <= since_dt:
                continue
            text = row.get("text")
            if not isinstance(text, str) or not text.strip():
                continue
            items.append({
                "id": row.get("id"),
                "role": "user",
                "content": text.strip(),
                "created_at": created_at,
                "updated_at": row.get("updated_at"),
            })

        for row in list_records("agent_status"):
            if row.get("session_id") != session_id:
                continue
            created_at = row.get("updated_at") or row.get("created_at") or now_iso()
            if since_dt is not None and to_dt(created_at) <= since_dt:
                continue
            text = make_agent_chat_text(row.get("headline"), row.get("detail"))
            if not text:
                continue
            items.append({
                "id": row.get("id"),
                "role": "assistant",
                "content": text,
                "created_at": created_at,
                "updated_at": row.get("updated_at"),
            })

        items.sort(key=lambda row: (to_dt(row.get("created_at")), str(row.get("id", ""))))
        if since_dt is None and len(items) > limit:
            items = items[-limit:]
        else:
            items = items[:limit]
        return jsonify({"items": items, "count": len(items)})

    # Legacy compatibility for Mac app transport.
    @app.post("/v1/agent")
    def v1_agent() -> Any:
        payload = request.get_json(silent=True) or {}
        session_id = str(payload.get("session_id") or payload.get("workspace_id") or str(uuid.uuid4()))
        metadata_obj = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
        model_raw = payload.get("model") or metadata_obj.get("model")
        model = model_raw.strip() if isinstance(model_raw, str) and model_raw.strip() else None
        input_obj = payload.get("input") if isinstance(payload.get("input"), dict) else {}
        message = input_obj.get("text", "") if isinstance(input_obj, dict) else ""
        if not isinstance(message, str) or not message.strip():
            return jsonify({"error": "input.text is required"}), 400
        message = message.strip()

        session_row = get_record("sessions", session_id)
        if not session_row:
            ts = now_iso()
            session_row = {
                "id": session_id,
                "created_at": ts,
                "updated_at": ts,
                "name": "Chat",
                "status": SESSION_STATUS_ACTIVE,
                "source_device_id": None,
                "metadata": {},
                "model": model or "gpt-5.2",
            }
            save_record("sessions", session_row)

        user_row_id = str(uuid.uuid4())
        user_ts = now_iso()
        save_record(
            "transcripts",
            {
                "id": user_row_id,
                "created_at": user_ts,
                "updated_at": user_ts,
                "captured_at": user_ts,
                "session_id": session_id,
                "device_id": "mac",
                "source": "chat",
                "text": message,
            },
        )
        touch_session(session_id)

        history_rows: list[tuple[datetime, str, dict[str, Any]]] = []
        for row in list_records("transcripts"):
            if row.get("session_id") == session_id:
                if row.get("id") == user_row_id:
                    continue
                history_rows.append((to_dt(row.get("created_at") or row.get("captured_at")), "user", row))
        for row in list_records("agent_status"):
            if row.get("session_id") == session_id:
                history_rows.append((to_dt(row.get("updated_at") or row.get("created_at")), "assistant", row))
        history_rows.sort(key=lambda item: item[0])

        messages: list[dict[str, Any]] = []
        for _, role, row in history_rows:
            if role == "user":
                text = row.get("text")
                if isinstance(text, str) and text.strip():
                    messages.append({"role": "user", "content": text.strip()})
            else:
                text = make_agent_chat_text(row.get("headline"), row.get("detail"))
                if text:
                    messages.append({"role": "assistant", "content": text})

        try:
            result = agent_module.run(messages, message, model=model)
        except Exception as exc:
            return jsonify({"error": str(exc)}), 500

        text = result.get("text") if isinstance(result, dict) else ""
        if not isinstance(text, str):
            text = ""
        widgets = result.get("widgets") if isinstance(result, dict) else []
        if not isinstance(widgets, list):
            widgets = []

        status_id = str(uuid.uuid4())
        status_ts = now_iso()
        save_record(
            "agent_status",
            {
                "id": status_id,
                "created_at": status_ts,
                "updated_at": status_ts,
                "session_id": session_id,
                "phase": "response",
                "headline": text.strip() or "Done",
                "detail": None,
                "source_device_id": "agent",
                "metadata": {"model": model or session_row.get("model") or "gpt-5.2"},
            },
        )
        touch_session(session_id)

        return jsonify({
            "text": text,
            "widgets": widgets,
            "session_id": session_id,
            "model": model or session_row.get("model") or "gpt-5.2",
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
        device_id = request.form.get("device_id")
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
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port, debug=True)

from __future__ import annotations

import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request, send_file
from werkzeug.utils import secure_filename


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
AUDIO_CHUNKS_DIR = DATA_DIR / "audio_chunks"
AUDIO_FINAL_DIR = DATA_DIR / "audio_final"
SCREENSHOTS_DIR = DATA_DIR / "screenshots"
DB_PATH = DATA_DIR / "iris.db"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dirs() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    AUDIO_CHUNKS_DIR.mkdir(exist_ok=True)
    AUDIO_FINAL_DIR.mkdir(exist_ok=True)
    SCREENSHOTS_DIR.mkdir(exist_ok=True)


def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with db_connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS audio_sessions (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                device_id TEXT,
                mime_type TEXT,
                status TEXT NOT NULL,
                audio_path TEXT,
                transcript TEXT
            );

            CREATE TABLE IF NOT EXISTS audio_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                chunk_path TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(session_id, chunk_index),
                FOREIGN KEY(session_id) REFERENCES audio_sessions(id)
            );

            CREATE TABLE IF NOT EXISTS screenshots (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                captured_at TEXT,
                device_id TEXT,
                source TEXT,
                mime_type TEXT,
                file_path TEXT NOT NULL,
                notes TEXT
            );
            """
        )


def run_migrations() -> None:
    with db_connect() as conn:
        columns = conn.execute("PRAGMA table_info(screenshots)").fetchall()
        column_names = {col["name"] for col in columns}
        if "captured_at" not in column_names:
            conn.execute("ALTER TABLE screenshots ADD COLUMN captured_at TEXT")


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


def session_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "device_id": row["device_id"],
        "mime_type": row["mime_type"],
        "status": row["status"],
        "audio_path": row["audio_path"],
        "transcript": row["transcript"],
    }


def screenshot_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "captured_at": row["captured_at"],
        "device_id": row["device_id"],
        "source": row["source"],
        "mime_type": row["mime_type"],
        "file_path": row["file_path"],
        "notes": row["notes"],
    }


def join_chunks(session_id: str, mime_type: str | None) -> Path:
    ext = ".bin"
    if mime_type:
        if "wav" in mime_type:
            ext = ".wav"
        elif "mpeg" in mime_type or "mp3" in mime_type:
            ext = ".mp3"
        elif "ogg" in mime_type:
            ext = ".ogg"
        elif "webm" in mime_type:
            ext = ".webm"
        elif "mp4" in mime_type or "m4a" in mime_type:
            ext = ".m4a"

    output_path = AUDIO_FINAL_DIR / f"{session_id}{ext}"

    with db_connect() as conn:
        rows = conn.execute(
            """
            SELECT chunk_path
            FROM audio_chunks
            WHERE session_id = ?
            ORDER BY chunk_index ASC
            """,
            (session_id,),
        ).fetchall()

    if not rows:
        raise ValueError("No chunks found for session")

    with output_path.open("wb") as out_file:
        for row in rows:
            chunk_path = Path(row["chunk_path"])
            with chunk_path.open("rb") as in_file:
                out_file.write(in_file.read())

    return output_path


def get_chunk_paths(session_id: str) -> list[Path]:
    with db_connect() as conn:
        rows = conn.execute(
            """
            SELECT chunk_path
            FROM audio_chunks
            WHERE session_id = ?
            ORDER BY chunk_index ASC
            """,
            (session_id,),
        ).fetchall()
    return [Path(row["chunk_path"]) for row in rows]


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
    run_migrations()

    app = Flask(__name__)

    @app.get("/health")
    def health() -> Any:
        return jsonify({"status": "ok", "ts": now_iso()})

    @app.post("/api/audio/sessions")
    def create_audio_session() -> Any:
        payload = request.get_json(silent=True) or {}
        session_id = str(uuid.uuid4())
        created_at = now_iso()
        device_id = payload.get("device_id")
        mime_type = payload.get("mime_type")

        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO audio_sessions (
                    id, created_at, updated_at, device_id, mime_type, status
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (session_id, created_at, created_at, device_id, mime_type, "collecting"),
            )
            row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()

        return jsonify(session_to_dict(row)), 201

    @app.post("/api/audio/sessions/<session_id>/chunks")
    def upload_audio_chunk(session_id: str) -> Any:
        chunk_index_raw = request.args.get("index", "").strip()
        if not chunk_index_raw.isdigit():
            return jsonify({"error": "index query parameter must be a non-negative integer"}), 400
        chunk_index = int(chunk_index_raw)

        with db_connect() as conn:
            session_row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if not session_row:
            return jsonify({"error": "audio session not found"}), 404

        if "chunk" in request.files:
            raw_bytes = request.files["chunk"].read()
        else:
            raw_bytes = request.get_data()

        if not raw_bytes:
            return jsonify({"error": "chunk payload is empty"}), 400

        chunk_path = AUDIO_CHUNKS_DIR / f"{session_id}_{chunk_index:08d}.part"
        with chunk_path.open("wb") as chunk_file:
            chunk_file.write(raw_bytes)

        ts = now_iso()
        with db_connect() as conn:
            conn.execute(
                """
                INSERT INTO audio_chunks (session_id, chunk_index, chunk_path, byte_size, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id, chunk_index) DO UPDATE SET
                    chunk_path = excluded.chunk_path,
                    byte_size = excluded.byte_size,
                    created_at = excluded.created_at
                """,
                (session_id, chunk_index, str(chunk_path), len(raw_bytes), ts),
            )
            conn.execute(
                """
                UPDATE audio_sessions
                SET updated_at = ?, status = ?
                WHERE id = ?
                """,
                (ts, "collecting", session_id),
            )

        return (
            jsonify(
                {
                    "session_id": session_id,
                    "chunk_index": chunk_index,
                    "byte_size": len(raw_bytes),
                    "stored_at": str(chunk_path),
                }
            ),
            201,
        )

    @app.post("/api/audio/sessions/<session_id>/finalize")
    def finalize_audio_session(session_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        transcript = payload.get("transcript")

        with db_connect() as conn:
            session_row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if not session_row:
            return jsonify({"error": "audio session not found"}), 404

        try:
            final_path = join_chunks(session_id, session_row["mime_type"])
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400

        status = "received"
        if transcript:
            status = "transcribed"

        ts = now_iso()
        chunk_paths = get_chunk_paths(session_id)
        with db_connect() as conn:
            conn.execute(
                """
                UPDATE audio_sessions
                SET updated_at = ?, audio_path = ?, transcript = COALESCE(?, transcript), status = ?
                WHERE id = ?
                """,
                (ts, str(final_path), transcript, status, session_id),
            )
            conn.execute("DELETE FROM audio_chunks WHERE session_id = ?", (session_id,))
            row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()

        delete_files(chunk_paths)
        return jsonify(session_to_dict(row))

    @app.put("/api/audio/sessions/<session_id>/transcript")
    def update_transcript(session_id: str) -> Any:
        payload = request.get_json(silent=True) or {}
        transcript = payload.get("text")
        if not isinstance(transcript, str) or not transcript.strip():
            return jsonify({"error": "text is required"}), 400

        ts = now_iso()
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if not row:
                return jsonify({"error": "audio session not found"}), 404

            conn.execute(
                """
                UPDATE audio_sessions
                SET updated_at = ?, transcript = ?, status = ?
                WHERE id = ?
                """,
                (ts, transcript.strip(), "transcribed", session_id),
            )
            row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()

        return jsonify(session_to_dict(row))

    @app.get("/api/audio/sessions/<session_id>")
    def get_audio_session(session_id: str) -> Any:
        with db_connect() as conn:
            row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if not row:
            return jsonify({"error": "audio session not found"}), 404
        return jsonify(session_to_dict(row))

    @app.delete("/api/audio/sessions/<session_id>")
    def delete_audio_session(session_id: str) -> Any:
        with db_connect() as conn:
            session_row = conn.execute(
                "SELECT * FROM audio_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if not session_row:
                return jsonify({"error": "audio session not found"}), 404

            chunk_rows = conn.execute(
                "SELECT chunk_path FROM audio_chunks WHERE session_id = ?",
                (session_id,),
            ).fetchall()
            conn.execute("DELETE FROM audio_chunks WHERE session_id = ?", (session_id,))
            conn.execute("DELETE FROM audio_sessions WHERE id = ?", (session_id,))

        paths_to_delete = [Path(row["chunk_path"]) for row in chunk_rows]
        if session_row["audio_path"]:
            paths_to_delete.append(Path(session_row["audio_path"]))
        file_stats = delete_files(paths_to_delete)

        return jsonify(
            {
                "id": session_id,
                "deleted": True,
                "files_removed": file_stats["removed"],
                "files_missing": file_stats["missing"],
                "files_failed": file_stats["failed"],
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
        source = request.form.get("source")
        notes = request.form.get("notes")
        captured_at_raw = request.form.get("captured_at")
        mime_type = shot.content_type

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
                    id, created_at, updated_at, captured_at, device_id, source, mime_type, file_path, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    screenshot_id,
                    created_at,
                    created_at,
                    captured_at,
                    device_id,
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


_app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    _app.run(host="0.0.0.0", port=port, debug=True)

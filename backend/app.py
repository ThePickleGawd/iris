"""Iris backend — single-JSON-per-session storage."""
from __future__ import annotations

import concurrent.futures
import json
import logging
import os
import hashlib
import queue
import subprocess
import tempfile
import threading
import traceback
import urllib.request
import uuid
from functools import lru_cache
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, Response, jsonify, request, send_file, stream_with_context
from werkzeug.utils import secure_filename

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
import claude_commander

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SESSIONS_DIR = DATA_DIR / "sessions"
SCREENSHOTS_DIR = DATA_DIR / "screenshots"
SCREENSHOTS_META_DIR = DATA_DIR / "screenshot_meta"
PROACTIVE_DESCRIPTIONS_DIR = DATA_DIR / "proactive_descriptions"
CODEX_SESSIONS_ROOT = Path(
    os.environ.get("CODEX_SESSIONS_ROOT", str(Path.home() / ".codex" / "sessions"))
)
CODEX_HISTORY_PATH = Path(
    os.environ.get("CODEX_HISTORY_PATH", str(Path.home() / ".codex" / "history.jsonl"))
)
CODEX_CLI_BIN = os.environ.get("CODEX_CLI_BIN", "codex")
IRIS_IPAD_URL = os.environ.get("IRIS_IPAD_URL", "http://dylans-ipad.local:8935")
CODEX_MESSAGE_DEDUP_WINDOW_SECONDS = 20
IRIS_TOOLS_MANIFEST_PATH = BASE_DIR.parent / "tools" / "iris-tools.json"

try:
    SCREENSHOT_RETENTION_LIMIT = max(1, int(os.environ.get("IRIS_SCREENSHOT_RETENTION_LIMIT", "50")))
except ValueError:
    SCREENSHOT_RETENTION_LIMIT = 50

_codex_rollout_cache: dict[str, Path] = {}

for d in [SESSIONS_DIR, SCREENSHOTS_DIR, SCREENSHOTS_META_DIR, PROACTIVE_DESCRIPTIONS_DIR]:
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


# ---------------------------------------------------------------------------
# Session message SSE pub/sub
# ---------------------------------------------------------------------------
_session_subscribers: dict[str, list[queue.Queue]] = {}
_subscribers_lock = threading.Lock()


def _subscribe(session_id: str) -> queue.Queue:
    q: queue.Queue = queue.Queue()
    with _subscribers_lock:
        _session_subscribers.setdefault(session_id, []).append(q)
    return q


def _unsubscribe(session_id: str, q: queue.Queue) -> None:
    with _subscribers_lock:
        subs = _session_subscribers.get(session_id)
        if subs:
            try:
                subs.remove(q)
            except ValueError:
                pass
            if not subs:
                del _session_subscribers[session_id]


def _publish_messages(session_id: str, messages: list[dict]) -> None:
    with _subscribers_lock:
        subs = list(_session_subscribers.get(session_id, []))
    for q in subs:
        try:
            q.put_nowait(messages)
        except queue.Full:
            pass


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


def _make_session(
    session_id: str,
    name: str = "Untitled",
    model: str = "gpt-5.2-mini",
    metadata: dict[str, Any] | None = None,
) -> dict:
    ts = _now()
    return {
        "id": session_id,
        "name": name,
        "model": model,
        "metadata": metadata or {},
        "created_at": ts,
        "updated_at": ts,
        "messages": [],
        "widgets": [],
    }


def _session_summary(session: dict) -> dict:
    """Return session metadata without the full messages array (for listings)."""
    # Build a short preview from the last non-empty message.
    preview = ""
    for msg in reversed(session.get("messages") or []):
        text = str(msg.get("content") or "").strip()
        if text:
            preview = text[:120]
            break
    return {
        "id": session["id"],
        "name": session.get("name", "Untitled"),
        "model": session.get("model", "gpt-5.2-mini"),
        "status": session.get("status", "active"),
        "metadata": session.get("metadata", {}),
        "created_at": session.get("created_at", ""),
        "updated_at": session.get("updated_at", ""),
        "last_message_preview": preview,
    }


@lru_cache(maxsize=1)
def _iris_system_prompt() -> str:
    override = str(os.environ.get("IRIS_LINKED_PROVIDER_SYSTEM_PROMPT") or "").strip()
    if override:
        return override
    builder = getattr(agent_module, "_build_system_prompt", None)
    if callable(builder):
        try:
            built = builder()
            if isinstance(built, str) and built.strip():
                return built
        except Exception:
            pass
    return (
        "You are Iris. Operate as a cross-device assistant, prioritize actionable outputs, "
        "and preserve consistency across Mac, iPad, and iPhone workflows."
    )


@lru_cache(maxsize=1)
def _iris_tools_manifest() -> dict[str, Any]:
    try:
        raw = json.loads(IRIS_TOOLS_MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"tools": []}
    return raw if isinstance(raw, dict) else {"tools": []}


@lru_cache(maxsize=1)
def _iris_claude_cli_bootstrap_prompt() -> str:
    """Compact first-turn context for Claude live sessions to use iris CLI."""
    manifest = _iris_tools_manifest()
    tools = manifest.get("tools") if isinstance(manifest.get("tools"), list) else []
    lines = [
        "Iris iPad CLI context:",
        "- Use the global `iris` command from any working directory.",
        "- iPad base URL is configured by `IRIS_IPAD_URL` (default `http://dylans-ipad.local:8935`).",
        "- Discover commands: `iris tools list`.",
        "- Get details: `iris tools describe <tool>`.",
    ]
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = str(tool.get("name") or "").strip()
        summary = str(tool.get("summary") or "").strip()
        cli = str(tool.get("cli") or "").strip()
        if not name:
            continue
        if summary and cli:
            lines.append(f"- `{name}`: {summary} Example: `{cli}`")
        elif summary:
            lines.append(f"- `{name}`: {summary}")
        elif cli:
            lines.append(f"- `{name}`: `{cli}`")
    lines.extend([
        "- Prefer `iris` CLI commands over raw curl when operating on iPad canvas/widgets.",
        "Apply these rules immediately when handling this request.",
    ])
    return "\n".join(lines)


def _session_needs_auto_name(session: dict) -> bool:
    """Check if a session still has a generic/placeholder name."""
    name = str(session.get("name") or "").strip()
    session_id = str(session.get("id") or "").strip()
    return (
        not name
        or name == "Untitled"
        or name == session_id
        or name.startswith("Chat ")
    )


def _auto_name_session(session: dict, user_message: str) -> None:
    """Generate and set a brief title for the session from the first user message."""
    try:
        title = agent_module.generate_session_title(user_message)
        if title and title != "Untitled":
            session["name"] = title
    except Exception:
        pass


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


def _fov_summary_from_metadata(metadata: dict[str, Any] | None) -> str:
    if not isinstance(metadata, dict):
        return "fov=unknown"
    snapshot = metadata.get("coordinate_snapshot")
    if not isinstance(snapshot, dict):
        return "fov=unknown"

    top_left = snapshot.get("viewportTopLeftAxis") if isinstance(snapshot.get("viewportTopLeftAxis"), dict) else {}
    bottom_right = snapshot.get("viewportBottomRightAxis") if isinstance(snapshot.get("viewportBottomRightAxis"), dict) else {}
    center = snapshot.get("viewportCenterAxis") if isinstance(snapshot.get("viewportCenterAxis"), dict) else {}
    size = snapshot.get("viewportSizeCanvas") if isinstance(snapshot.get("viewportSizeCanvas"), dict) else {}

    return (
        "fov_axis_top_left=({:.2f},{:.2f}) "
        "fov_axis_bottom_right=({:.2f},{:.2f}) "
        "fov_axis_center=({:.2f},{:.2f}) "
        "fov_canvas_size=({:.2f},{:.2f})"
    ).format(
        float(top_left.get("x", 0.0)),
        float(top_left.get("y", 0.0)),
        float(bottom_right.get("x", 0.0)),
        float(bottom_right.get("y", 0.0)),
        float(center.get("x", 0.0)),
        float(center.get("y", 0.0)),
        float(size.get("width", 0.0)),
        float(size.get("height", 0.0)),
    )


# ---------------------------------------------------------------------------
# Codex sync helpers
# ---------------------------------------------------------------------------
def _parse_iso_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _normalize_iso_timestamp(value: Any) -> str:
    parsed = _parse_iso_timestamp(value)
    if parsed is None:
        return _now()
    return parsed.isoformat()


def _is_codex_session(session: dict) -> bool:
    model = str(session.get("model") or "").strip().lower()
    metadata = session.get("metadata") if isinstance(session.get("metadata"), dict) else {}
    return model == "codex" or bool(str(metadata.get("codex_conversation_id") or "").strip())


def _extract_codex_message_text(content: Any) -> str:
    if not isinstance(content, list):
        return ""
    chunks: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("type") or "")
        if kind not in ("input_text", "output_text"):
            continue
        text = item.get("text")
        if isinstance(text, str) and text.strip():
            chunks.append(text.strip())
    return "\n\n".join(chunks).strip()


def _is_internal_codex_user_message(text: str) -> bool:
    t = text.strip()
    internal_prefixes = (
        "<permissions instructions>",
        "<environment_context>",
        "# AGENTS.md instructions",
        "<INSTRUCTIONS>",
    )
    return any(t.startswith(prefix) for prefix in internal_prefixes)


def _resolve_codex_rollout_path(conversation_id: str) -> Path | None:
    cached = _codex_rollout_cache.get(conversation_id)
    if cached and cached.exists():
        return cached
    if not CODEX_SESSIONS_ROOT.exists():
        return None

    def _mtime(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0

    candidates = sorted(CODEX_SESSIONS_ROOT.rglob("*.jsonl"), key=_mtime, reverse=True)
    for path in candidates:
        try:
            with path.open("r", encoding="utf-8") as fh:
                first_line = fh.readline().strip()
            if not first_line:
                continue
            parsed = json.loads(first_line)
            payload = parsed.get("payload") if isinstance(parsed, dict) else {}
            if not isinstance(payload, dict):
                continue
            if str(payload.get("id") or "").strip() != conversation_id:
                continue
            _codex_rollout_cache[conversation_id] = path
            return path
        except (OSError, json.JSONDecodeError):
            continue
    return None


def _discover_codex_sessions(limit: int = 200) -> list[dict[str, Any]]:
    """Discover Codex conversations and map them to Iris session IDs when available."""
    by_conversation: dict[str, dict[str, Any]] = {}

    for item in _scan_codex_rollout_sessions(limit=max(limit * 3, 200)):
        conversation_id = str(item.get("conversation_id") or "").strip()
        if not conversation_id:
            continue
        by_conversation[conversation_id] = item

    for item in _scan_codex_history_sessions(limit=max(limit * 5, 300)):
        conversation_id = str(item.get("conversation_id") or "").strip()
        if not conversation_id:
            continue
        existing = by_conversation.get(conversation_id)
        if existing is None:
            by_conversation[conversation_id] = item
            continue
        if str(existing.get("updated_at") or "") < str(item.get("updated_at") or ""):
            existing["updated_at"] = item.get("updated_at")
        if not str(existing.get("preview") or "").strip() and str(item.get("preview") or "").strip():
            existing["preview"] = item.get("preview")
        if not str(existing.get("title") or "").strip() and str(item.get("title") or "").strip():
            existing["title"] = item.get("title")

    linked_by_conversation: dict[str, dict[str, Any]] = {}
    for session in _list_sessions():
        metadata = session.get("metadata") if isinstance(session.get("metadata"), dict) else {}
        conversation_id = str(metadata.get("codex_conversation_id") or "").strip()
        if not conversation_id:
            continue
        candidate = {
            "session_id": str(session.get("id") or "").strip(),
            "session_name": str(session.get("name") or "").strip() or "Untitled",
            "updated_at": str(session.get("updated_at") or ""),
            "preview": str(_session_summary(session).get("last_message_preview") or "").strip(),
            "cwd": str(metadata.get("codex_cwd") or "").strip() or None,
        }
        current = linked_by_conversation.get(conversation_id)
        if current is None or str(candidate.get("updated_at") or "") > str(current.get("updated_at") or ""):
            linked_by_conversation[conversation_id] = candidate

    items: list[dict[str, Any]] = []
    for conversation_id, discovered in by_conversation.items():
        linked = linked_by_conversation.get(conversation_id)
        if linked:
            session_id = str(linked.get("session_id") or "").strip()
            name = str(linked.get("session_name") or "").strip() or str(discovered.get("title") or "").strip()
            updated_at = str(linked.get("updated_at") or "").strip() or str(discovered.get("updated_at") or "")
            preview = str(linked.get("preview") or "").strip() or str(discovered.get("preview") or "")
            cwd = str(linked.get("cwd") or "").strip() or str(discovered.get("cwd") or "")
        else:
            session_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"iris:codex:{conversation_id}"))
            name = str(discovered.get("title") or "").strip()
            updated_at = str(discovered.get("updated_at") or "")
            preview = str(discovered.get("preview") or "").strip()
            cwd = str(discovered.get("cwd") or "").strip()

        if not name:
            name = f"Codex {conversation_id[:8]}"
        items.append(
            {
                "id": conversation_id,
                "conversation_id": conversation_id,
                "session_id": session_id,
                "title": name,
                "name": name,
                "model": "codex",
                "cwd": cwd or None,
                "updated_at": updated_at,
                "timestamp": updated_at,
                "last_message_preview": preview,
                "preview": preview,
            }
        )

    # Include linked backend Codex sessions even if they are not discoverable in rollout/history files.
    for conversation_id, linked in linked_by_conversation.items():
        if any(str(item.get("conversation_id") or "") == conversation_id for item in items):
            continue
        session_id = str(linked.get("session_id") or "").strip()
        name = str(linked.get("session_name") or "").strip() or f"Codex {conversation_id[:8]}"
        updated_at = str(linked.get("updated_at") or "")
        preview = str(linked.get("preview") or "").strip()
        items.append(
            {
                "id": conversation_id,
                "conversation_id": conversation_id,
                "session_id": session_id,
                "title": name,
                "name": name,
                "model": "codex",
                "cwd": linked.get("cwd"),
                "updated_at": updated_at,
                "timestamp": updated_at,
                "last_message_preview": preview,
                "preview": preview,
            }
        )

    items.sort(key=lambda row: str(row.get("updated_at") or ""), reverse=True)
    return items[:limit]


def _scan_codex_rollout_sessions(limit: int = 200) -> list[dict[str, Any]]:
    if not CODEX_SESSIONS_ROOT.exists():
        return []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()

    def _mtime(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0

    candidates = sorted(CODEX_SESSIONS_ROOT.rglob("*.jsonl"), key=_mtime, reverse=True)
    for path in candidates:
        if len(items) >= limit:
            break
        try:
            with path.open("r", encoding="utf-8") as fh:
                first_line = fh.readline().strip()
            if not first_line:
                continue
            parsed = json.loads(first_line)
            payload = parsed.get("payload") if isinstance(parsed, dict) else {}
            if not isinstance(payload, dict):
                continue
            conversation_id = str(payload.get("id") or "").strip()
            if not conversation_id or conversation_id in seen:
                continue
            seen.add(conversation_id)
            timestamp = _normalize_iso_timestamp(payload.get("timestamp"))
            cwd = str(payload.get("cwd") or "").strip()
            title = Path(cwd).name if cwd else f"Codex {conversation_id[:8]}"
            items.append(
                {
                    "conversation_id": conversation_id,
                    "title": title,
                    "updated_at": timestamp,
                    "cwd": cwd or None,
                    "preview": "",
                }
            )
        except (OSError, json.JSONDecodeError):
            continue
    return items


def _scan_codex_history_sessions(limit: int = 300) -> list[dict[str, Any]]:
    if not CODEX_HISTORY_PATH.exists():
        return []
    latest: dict[str, dict[str, Any]] = {}
    try:
        with CODEX_HISTORY_PATH.open("r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                conversation_id = str(row.get("session_id") or "").strip()
                if not conversation_id:
                    continue
                ts = row.get("ts")
                updated_at = _history_ts_to_iso(ts)
                preview = str(row.get("text") or "").strip()
                existing = latest.get(conversation_id)
                if existing is None or str(existing.get("updated_at") or "") <= updated_at:
                    latest[conversation_id] = {
                        "conversation_id": conversation_id,
                        "updated_at": updated_at,
                        "preview": preview[:120],
                        "title": f"Codex {conversation_id[:8]}",
                        "cwd": None,
                    }
    except OSError:
        return []

    items = sorted(latest.values(), key=lambda row: str(row.get("updated_at") or ""), reverse=True)
    return items[:limit]


def _history_ts_to_iso(value: Any) -> str:
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value), tz=timezone.utc).isoformat()
        except (OSError, OverflowError, ValueError):
            return _now()
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            return _now()
        if trimmed.isdigit():
            try:
                return datetime.fromtimestamp(float(trimmed), tz=timezone.utc).isoformat()
            except (OSError, OverflowError, ValueError):
                pass
        return _normalize_iso_timestamp(trimmed)
    return _now()


def _codex_event_external_id(
    conversation_id: str, timestamp: str, role: str, phase: str, text: str
) -> str:
    digest = hashlib.sha1(
        f"{conversation_id}|{timestamp}|{role}|{phase}|{text}".encode("utf-8")
    ).hexdigest()
    return f"codex:{conversation_id}:{digest}"


def _has_equivalent_message(session_messages: list[dict], role: str, text: str, created_at: str) -> bool:
    normalized = text.strip()
    if not normalized:
        return True
    target_ts = _parse_iso_timestamp(created_at)
    for msg in session_messages:
        if msg.get("role") != role:
            continue
        if str(msg.get("content") or "").strip() != normalized:
            continue
        if target_ts is None:
            return True
        existing_ts = _parse_iso_timestamp(msg.get("created_at"))
        if existing_ts is None:
            return True
        if abs((existing_ts - target_ts).total_seconds()) <= CODEX_MESSAGE_DEDUP_WINDOW_SECONDS:
            return True
    return False


def _load_codex_rollout_messages(conversation_id: str) -> list[dict]:
    path = _resolve_codex_rollout_path(conversation_id)
    if path is None:
        return []
    items: list[dict] = []
    try:
        with path.open("r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                if row.get("type") != "response_item":
                    continue
                payload = row.get("payload")
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") != "message":
                    continue
                role = str(payload.get("role") or "").strip()
                if role not in ("user", "assistant"):
                    continue
                text = _extract_codex_message_text(payload.get("content"))
                if not text:
                    continue
                if role == "user" and _is_internal_codex_user_message(text):
                    continue
                phase = str(payload.get("phase") or "").strip()
                created_at = _normalize_iso_timestamp(row.get("timestamp"))
                external_id = _codex_event_external_id(
                    conversation_id, created_at, role, phase, text
                )
                items.append(
                    {
                        "role": role,
                        "content": text,
                        "created_at": created_at,
                        "external_id": external_id,
                        "source": f"codex:{phase}" if phase else "codex",
                    }
                )
    except OSError:
        return []
    return items


def _sync_codex_messages_for_session(session: dict) -> int:
    metadata = session.get("metadata") if isinstance(session.get("metadata"), dict) else {}
    conversation_id = str(metadata.get("codex_conversation_id") or "").strip()
    if not conversation_id:
        return 0
    rollout_messages = _load_codex_rollout_messages(conversation_id)
    if not rollout_messages:
        return 0

    messages = session.setdefault("messages", [])
    existing_external_ids = {
        str(m.get("external_id") or "").strip()
        for m in messages
        if isinstance(m, dict) and str(m.get("external_id") or "").strip()
    }
    inserted = 0
    for rollout_msg in rollout_messages:
        external_id = rollout_msg["external_id"]
        if external_id in existing_external_ids:
            continue
        if _has_equivalent_message(
            messages,
            rollout_msg["role"],
            rollout_msg["content"],
            rollout_msg["created_at"],
        ):
            existing_external_ids.add(external_id)
            continue
        messages.append(
            {
                "id": str(uuid.uuid4()),
                "role": rollout_msg["role"],
                "content": rollout_msg["content"],
                "created_at": rollout_msg["created_at"],
                "device_id": "codex",
                "source": rollout_msg["source"],
                "external_id": external_id,
            }
        )
        existing_external_ids.add(external_id)
        inserted += 1

    if inserted:
        messages.sort(key=lambda m: str(m.get("created_at") or ""))
        session["updated_at"] = str(messages[-1].get("created_at") or _now())
    return inserted


def _extract_codex_error(raw: str) -> str | None:
    fallback = ""
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("{") and stripped.endswith("}"):
            try:
                parsed = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(parsed, dict)
                and parsed.get("type") == "error"
                and isinstance(parsed.get("message"), str)
                and parsed["message"].strip()
            ):
                return parsed["message"].strip()
            nested = parsed.get("error") if isinstance(parsed, dict) else None
            if isinstance(nested, dict):
                nested_msg = nested.get("message")
                if isinstance(nested_msg, str) and nested_msg.strip():
                    fallback = nested_msg.strip()
            continue
        if stripped.startswith("WARNING:"):
            continue
        if "codex_core::" in stripped:
            continue
        fallback = stripped
    return fallback or None


def _run_codex_resume(conversation_id: str, prompt: str, cwd: str | None = None) -> str:
    with tempfile.NamedTemporaryFile(prefix="iris-codex-last-", suffix=".txt", delete=False) as tmp:
        output_path = Path(tmp.name)
    args = [
        CODEX_CLI_BIN,
        "exec",
        "--output-last-message",
        str(output_path),
        "--dangerously-bypass-approvals-and-sandbox",
        "-c",
        f"base_instructions={json.dumps(_iris_system_prompt())}",
    ]
    if cwd:
        args.extend(["--cd", cwd])
    args.extend(["resume", conversation_id, prompt, "--json", "--skip-git-repo-check"])
    try:
        result = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        output_path.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to launch Codex CLI: {exc}") from exc

    try:
        text = output_path.read_text(encoding="utf-8").strip()
    except OSError:
        text = ""
    finally:
        output_path.unlink(missing_ok=True)

    if result.returncode != 0:
        detail = _extract_codex_error(result.stderr) or _extract_codex_error(result.stdout)
        raise RuntimeError(detail or f"Codex exited with status {result.returncode}")
    if not text:
        detail = _extract_codex_error(result.stderr) or _extract_codex_error(result.stdout)
        raise RuntimeError(detail or "Codex returned no assistant text")
    return text


def _linked_provider_keys(provider: str) -> tuple[str, str]:
    if provider == "codex":
        return ("codex_conversation_id", "codex_cwd")
    if provider == "claude_code":
        return ("claude_code_conversation_id", "claude_code_cwd")
    raise ValueError(f"Unsupported provider: {provider}")


def _linked_provider_name(provider: str) -> str:
    if provider == "codex":
        return "Codex"
    if provider == "claude_code":
        return "Claude Code"
    return provider


def _linked_provider_bootstrap_prompt(provider: str) -> str:
    name = _linked_provider_name(provider)
    return (
        f"This is a bootstrap turn for a new Iris-linked {name} session. "
        f"Reply with exactly: {name} session ready."
    )


def _run_codex_new_session(prompt: str, cwd: str | None = None) -> tuple[str, str]:
    args = [
        CODEX_CLI_BIN,
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        "-c",
        f"base_instructions={json.dumps(_iris_system_prompt())}",
    ]
    if cwd:
        args.extend(["--cd", cwd])
    args.append(prompt)

    try:
        result = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise RuntimeError(f"Failed to launch Codex CLI: {exc}") from exc

    conversation_id = ""
    assistant_text = ""
    for raw in result.stdout.splitlines():
        stripped = raw.strip()
        if not stripped or not stripped.startswith("{"):
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        row_type = str(row.get("type") or "").strip()
        if row_type == "thread.started":
            conversation_id = str(row.get("thread_id") or "").strip() or conversation_id
            continue
        if row_type != "item.completed":
            continue
        item = row.get("item")
        if not isinstance(item, dict):
            continue
        if str(item.get("type") or "") != "agent_message":
            continue
        text = item.get("text")
        if isinstance(text, str) and text.strip():
            assistant_text = text.strip()

    if result.returncode != 0:
        detail = _extract_codex_error(result.stderr) or _extract_codex_error(result.stdout)
        raise RuntimeError(detail or f"Codex exited with status {result.returncode}")

    if not conversation_id:
        raise RuntimeError("Codex did not return a new session id")
    return (conversation_id, assistant_text)


def _start_linked_provider_session(
    provider: str,
    *,
    name: str | None = None,
    cwd: str | None = None,
    prompt: str | None = None,
) -> dict[str, Any]:
    clean_cwd = (cwd or "").strip() or None
    bootstrap_prompt = (prompt or "").strip() or _linked_provider_bootstrap_prompt(provider)

    if provider == "codex":
        conversation_id, _assistant_text = _run_codex_new_session(bootstrap_prompt, clean_cwd)
    else:
        raise ValueError(f"Unsupported provider: {provider}")

    session_id = str(uuid.uuid4())
    session_name = (name or "").strip()
    if not session_name:
        session_name = f"{_linked_provider_name(provider)} {datetime.now().strftime('%I:%M:%S %p').lstrip('0')}"
    metadata: dict[str, Any] = {}
    conversation_key, cwd_key = _linked_provider_keys(provider)
    metadata[conversation_key] = conversation_id
    if clean_cwd:
        metadata[cwd_key] = clean_cwd

    session = _make_session(session_id, session_name, provider, metadata=metadata)
    _save_session(session)

    summary = _session_summary(session)
    summary["conversation_id"] = conversation_id
    summary["provider"] = provider
    summary["cwd"] = clean_cwd
    return summary


def _run_linked_provider(provider: str, conversation_id: str, prompt: str, cwd: str | None) -> str:
    if provider == "codex":
        return _run_codex_resume(conversation_id, prompt, cwd)
    raise ValueError(f"Unsupported provider: {provider}")


def _sync_linked_provider_messages(session: dict, provider: str) -> int:
    if provider == "codex":
        return _sync_codex_messages_for_session(session)
    return 0


def _execute_linked_provider(
    session: dict,
    *,
    provider: str,
    prompt: str,
    device_id: str | None,
    conversation_id: str | None = None,
    cwd: str | None = None,
    source_suffix: str = "api",
) -> dict[str, Any]:
    conversation_key, cwd_key = _linked_provider_keys(provider)
    metadata = session.setdefault("metadata", {})
    if conversation_id and conversation_id.strip():
        metadata[conversation_key] = conversation_id.strip()
    resolved_conversation_id = str(metadata.get(conversation_key) or "").strip()
    if not resolved_conversation_id:
        raise ValueError(f"{conversation_key} is required for {provider} sessions")

    if cwd and cwd.strip():
        metadata[cwd_key] = cwd.strip()
    resolved_cwd = str(metadata.get(cwd_key) or "").strip() or None

    text = _run_linked_provider(provider, resolved_conversation_id, prompt, resolved_cwd)
    inserted = _sync_linked_provider_messages(session, provider)

    has_user = _has_equivalent_message(session.get("messages", []), "user", prompt, _now())
    has_assistant = _has_equivalent_message(
        session.get("messages", []), "assistant", text, _now()
    )
    new_msgs = []
    if not has_user:
        user_ts = _now()
        umsg = {
            "id": str(uuid.uuid4()),
            "role": "user",
            "content": prompt,
            "created_at": user_ts,
            "device_id": device_id,
            "source": f"{provider}.{source_suffix}",
        }
        session.setdefault("messages", []).append(umsg)
        new_msgs.append(umsg)
    if not has_assistant:
        assistant_ts = _now()
        amsg = {
            "id": str(uuid.uuid4()),
            "role": "assistant",
            "content": text,
            "created_at": assistant_ts,
            "device_id": provider,
            "source": f"{provider}.{source_suffix}",
        }
        session["messages"].append(amsg)
        new_msgs.append(amsg)
    if new_msgs:
        _publish_messages(session["id"], new_msgs)
    if not has_user or not has_assistant:
        inserted += int(not has_user) + int(not has_assistant)

    session["messages"].sort(key=lambda m: str(m.get("created_at") or ""))
    session["updated_at"] = str(session["messages"][-1].get("created_at") or _now())
    return {
        "text": text,
        "conversation_id": resolved_conversation_id,
        "cwd": resolved_cwd,
        "synced_messages": inserted,
    }


# ---------------------------------------------------------------------------
# Screenshot storage helpers (kept simple — separate files)
# ---------------------------------------------------------------------------


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


def _delete_screenshot_row(row: dict[str, Any]) -> None:
    screenshot_id = str(row.get("id") or "").strip()
    if screenshot_id:
        _screenshot_meta_path(screenshot_id).unlink(missing_ok=True)
        (PROACTIVE_DESCRIPTIONS_DIR / f"{screenshot_id}.json").unlink(missing_ok=True)

    file_path = Path(str(row.get("file_path") or ""))
    if file_path.name:
        file_path.unlink(missing_ok=True)


def _prune_screenshots(limit: int = SCREENSHOT_RETENTION_LIMIT) -> int:
    rows = _list_screenshots()
    if len(rows) <= limit:
        return 0
    rows.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
    to_delete = rows[limit:]
    for row in to_delete:
        _delete_screenshot_row(row)
    return len(to_delete)


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
    model = (body.get("model") or body.get("agent") or "gpt-5.2-mini").strip()
    name = (body.get("name") or "Untitled").strip()
    metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else None

    existing = _load_session(session_id)
    if existing:
        existing["updated_at"] = _now()
        if body.get("name"):
            # Don't overwrite a meaningful name with a generic placeholder
            existing_has_real_name = not _session_needs_auto_name(existing)
            incoming_is_generic = _session_needs_auto_name({"name": name, "id": session_id})
            if not (existing_has_real_name and incoming_is_generic):
                existing["name"] = name
        if body.get("model") or body.get("agent"):
            existing["model"] = model
        if metadata is not None:
            existing["metadata"] = metadata
        _save_session(existing)
        return jsonify(_session_summary(existing)), 201

    session = _make_session(session_id, name, model, metadata=metadata)
    _save_session(session)
    return jsonify(_session_summary(session)), 201


@app.get("/api/sessions")
@app.get("/sessions")
def list_sessions() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    status_filter = (request.args.get("status") or "").strip().lower()
    rows = [_session_summary(s) for s in _list_sessions()]
    if status_filter:
        rows = [r for r in rows if (r.get("status", "active") or "").lower() == status_filter]
    rows.sort(key=lambda r: r.get("updated_at", ""), reverse=True)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.get("/api/sessions/<session_id>")
@app.get("/sessions/<session_id>")
def get_session(session_id: str) -> Any:
    session = _load_session(session_id)
    if not session:
        return jsonify({"error": "session not found"}), 404

    # Filter widgets by target device when ?target= is provided
    target = (request.args.get("target") or "").strip().lower()
    if target:
        filtered = dict(session)
        filtered["widgets"] = [
            w for w in session.get("widgets", [])
            if (w.get("target") or "mac").lower() == target
        ]
        return jsonify(filtered)

    return jsonify(session)


@app.delete("/api/sessions/<session_id>")
@app.delete("/sessions/<session_id>")
def delete_session(session_id: str) -> Any:
    if not _load_session(session_id):
        return jsonify({"error": "session not found"}), 404
    _delete_session(session_id)
    return jsonify({"id": session_id, "deleted": True})


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
    _save_session(session)
    return jsonify({"id": widget_id, "deleted": True})


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
    external_id = str(body.get("external_id") or "").strip()

    # Dedup by id
    if any(m.get("id") == msg_id for m in session.get("messages", [])):
        existing_msg = next(m for m in session["messages"] if m.get("id") == msg_id)
        return jsonify(existing_msg), 201
    if external_id and any(str(m.get("external_id") or "").strip() == external_id for m in session.get("messages", [])):
        existing_msg = next(
            m for m in session["messages"] if str(m.get("external_id") or "").strip() == external_id
        )
        return jsonify(existing_msg), 201

    ts = _normalize_iso_timestamp(body.get("created_at") or _now())
    msg = {
        "id": msg_id,
        "role": role,
        "content": content.strip(),
        "created_at": ts,
        "device_id": body.get("device_id"),
        "source": body.get("source"),
        "external_id": external_id or None,
    }
    session.setdefault("messages", []).append(msg)
    session["messages"].sort(key=lambda m: str(m.get("created_at") or ""))
    session["updated_at"] = str(session["messages"][-1].get("created_at") or ts)
    _save_session(session)
    _publish_messages(session_id, [msg])
    return jsonify(msg), 201


@app.get("/api/sessions/<session_id>/messages")
@app.get("/sessions/<session_id>/messages")
def list_messages(session_id: str) -> Any:
    limit = min(int(request.args.get("limit", 200)), 200)
    since = request.args.get("since")

    session = _load_session(session_id)
    if not session:
        return jsonify({"items": [], "count": 0})

    inserted = 0
    if _is_codex_session(session):
        inserted = _sync_codex_messages_for_session(session)
    if inserted:
        _save_session(session)

    msgs = sorted(session.get("messages", []), key=lambda m: str(m.get("created_at") or ""))
    if since:
        msgs = [m for m in msgs if m.get("created_at", "") > since]
    elif len(msgs) > limit:
        msgs = msgs[-limit:]

    return jsonify({"items": msgs[:limit], "count": min(len(msgs), limit)})


@app.get("/api/sessions/<session_id>/events")
@app.get("/sessions/<session_id>/events")
def session_events(session_id: str) -> Any:
    """SSE stream — pushes new messages as they are appended to the session."""
    q = _subscribe(session_id)

    def generate():
        try:
            # Send a keepalive comment immediately so the client knows we're connected.
            yield ": connected\n\n"
            while True:
                try:
                    messages = q.get(timeout=25)
                    payload = json.dumps(messages, ensure_ascii=False)
                    yield f"data: {payload}\n\n"
                except queue.Empty:
                    # Keepalive every 25s to prevent connection timeout.
                    yield ": keepalive\n\n"
        except GeneratorExit:
            pass
        finally:
            _unsubscribe(session_id, q)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ---------------------------------------------------------------------------
# Codex bridge
# ---------------------------------------------------------------------------

@app.get("/api/codex/sessions")
@app.get("/codex/sessions")
def list_codex_sessions() -> Any:
    limit = min(int(request.args.get("limit", 50)), 200)
    rows = _discover_codex_sessions(limit=limit)
    return jsonify({"items": rows[:limit], "count": min(len(rows), limit)})


@app.post("/api/linked-sessions/start")
@app.post("/linked-sessions/start")
def start_linked_session() -> Any:
    body = request.get_json(silent=True) or {}
    provider = str(body.get("provider") or "").strip().lower()

    if provider == "claude_code":
        return jsonify({"error": "Use claudei on the Mac to start Claude Code sessions"}), 400

    if provider != "codex":
        return jsonify({"error": "provider must be 'codex'"}), 400

    name = str(body.get("name") or "").strip() or None
    cwd = str(body.get("cwd") or "").strip() or None
    prompt = str(body.get("prompt") or "").strip() or None

    try:
        created = _start_linked_provider_session(
            provider,
            name=name,
            cwd=cwd,
            prompt=prompt,
        )
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 502

    return jsonify(created), 201


def _start_linked_session_for_provider(provider: str) -> Any:
    body = request.get_json(silent=True) or {}
    name = str(body.get("name") or "").strip() or None
    cwd = str(body.get("cwd") or "").strip() or None
    prompt = str(body.get("prompt") or "").strip() or None
    try:
        created = _start_linked_provider_session(
            provider,
            name=name,
            cwd=cwd,
            prompt=prompt,
        )
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 502
    return jsonify(created), 201


@app.post("/api/codex/sessions/start")
@app.post("/codex/sessions/start")
def start_codex_session() -> Any:
    return _start_linked_session_for_provider("codex")


@app.post("/api/codex/respond")
@app.post("/codex/respond")
def codex_respond() -> Any:
    body = request.get_json(silent=True) or {}
    session_id = str(body.get("session_id") or "").strip()
    prompt = str(body.get("prompt") or "").strip()
    if not session_id:
        return jsonify({"error": "session_id is required"}), 400
    if not prompt:
        return jsonify({"error": "prompt is required"}), 400

    session = _load_session(session_id)
    if not session:
        session = _make_session(session_id, session_id, "codex")
    session["model"] = "codex"

    try:
        result = _execute_linked_provider(
            session,
            provider="codex",
            prompt=prompt,
            device_id=body.get("device_id"),
            conversation_id=str(body.get("conversation_id") or "").strip() or None,
            cwd=str(body.get("cwd") or "").strip() or None,
            source_suffix="api",
        )
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 502

    _save_session(session)

    return jsonify(
        {
            "ok": True,
            "session_id": session_id,
            "conversation_id": result["conversation_id"],
            "model": "codex",
            "text": result["text"],
            "synced_messages": result["synced_messages"],
            "timestamp": _now(),
        }
    )


@app.post("/api/claude-code/respond")
@app.post("/claude-code/respond")
def claude_code_respond() -> Any:
    body = request.get_json(silent=True) or {}
    session_id = str(body.get("session_id") or "").strip()
    prompt = str(body.get("prompt") or "").strip()
    if not session_id:
        return jsonify({"error": "session_id is required"}), 400
    if not prompt:
        return jsonify({"error": "prompt is required"}), 400

    live = claude_commander.get_live_session()
    if not live:
        return jsonify({"error": "No live session. Run `claudei` in your project on the Mac."}), 503

    socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)
    ok = claude_commander.inject_text(prompt, socket_path)
    if not ok:
        return jsonify({"error": "Failed to inject into live session"}), 502
    claude_commander.mark_busy()
    return jsonify({
        "ok": True,
        "session_id": session_id,
        "model": "claude_code",
        "mode": "live",
        "status": "sent",
        "text": "(sent to live Claude Code session)",
        "timestamp": _now(),
    })


@app.post("/api/claude-code/sessions/start")
@app.post("/claude-code/sessions/start")
def start_claude_code_session() -> Any:
    """Check for a live claude-commander session. Returns session info or 503."""
    live = claude_commander.get_live_session()
    if not live:
        return jsonify({
            "error": "No live session. Run `claudei` in your project on the Mac.",
            "live": False,
        }), 503

    socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)
    return jsonify({
        "ok": True,
        "live": True,
        "mode": "live",
        "socket_path": socket_path,
        "cwd": live.get("cwd"),
        "pid": live.get("pid"),
        "timestamp": _now(),
    })


# ---------------------------------------------------------------------------
# Claude Code live injection (claude-commander)
# ---------------------------------------------------------------------------

@app.post("/api/claude-code/inject")
def claude_code_inject() -> Any:
    """Inject a message (text + optional image) into a live Claude Code session."""
    body = request.get_json(silent=True) or {}
    text = str(body.get("text") or "").strip()
    image_base64 = str(body.get("image_base64") or "").strip() or None
    image_path = str(body.get("image_path") or "").strip() or None

    if not text and not image_base64 and not image_path:
        return jsonify({"error": "text, image_base64, or image_path is required"}), 400

    live = claude_commander.get_live_session()
    if not live:
        return jsonify({"error": "No live session. Run `claudei` in your project on the Mac."}), 503

    socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)

    # Handle image injection
    if image_base64 or image_path:
        ok = claude_commander.inject_image(
            image_path=image_path,
            image_base64=image_base64,
            prompt=text,
            socket_path=socket_path,
        )
        if not ok:
            return jsonify({"error": "Failed to inject image into live session"}), 502
        claude_commander.mark_busy()
        return jsonify({"status": "sent", "mode": "live", "type": "image", "timestamp": _now()})

    # Handle text injection
    ok = claude_commander.inject_text(text, socket_path)
    if not ok:
        return jsonify({"error": "Failed to inject text into live session"}), 502
    claude_commander.mark_busy()
    return jsonify({"status": "sent", "mode": "live", "type": "text", "timestamp": _now()})


@app.post("/api/claude-code/idle")
def claude_code_idle() -> Any:
    """Called by Claude Code's Stop hook to signal it's ready for the next message."""
    claude_commander.mark_idle()
    return jsonify({"status": "idle", "timestamp": _now()})


@app.get("/api/claude-code/live-status")
def claude_code_live_status() -> Any:
    """Check if a live claude-commander session is active."""
    live = claude_commander.get_live_session()
    if not live:
        return jsonify({"live": False})

    socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)
    status = claude_commander.get_status(socket_path)
    return jsonify({
        "live": True,
        "idle": claude_commander.is_idle(),
        "socket_path": socket_path,
        "cwd": live.get("cwd"),
        "pid": live.get("pid"),
        "commander_status": status,
        "timestamp": _now(),
    })


@app.get("/api/claude-code/sessions")
@app.get("/claude-code/sessions")
def list_claude_code_sessions() -> Any:
    """List active claudei sessions for the iPad picker."""
    live = claude_commander.get_live_session()
    if not live:
        return jsonify({"items": []})

    socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)
    cwd = live.get("cwd") or ""
    pid = live.get("pid")
    registered_at = live.get("registered_at")
    started_at = live.get("started_at") or ""

    name = os.path.basename(cwd) if cwd else "Claude Code"

    items = [{
        "id": socket_path,
        "name": name,
        "cwd": cwd,
        "pid": pid,
        "socket_path": socket_path,
        "started_at": started_at,
        "registered_at": registered_at,
        "idle": claude_commander.is_idle(),
    }]
    return jsonify({"items": items})


@app.post("/api/claude-code/sessions/register")
def register_claude_code_session() -> Any:
    """Register a live claude-commander session (called by tools/claudei)."""
    body = request.get_json(silent=True) or {}
    socket_path = str(body.get("socket_path") or "").strip()
    if not socket_path:
        return jsonify({"error": "socket_path is required"}), 400
    cwd = str(body.get("cwd") or "").strip() or None
    pid = body.get("pid")
    claude_commander.register_session(socket_path, cwd=cwd, pid=pid)
    return jsonify({"ok": True, "socket_path": socket_path})


@app.post("/api/claude-code/sessions/unregister")
def unregister_claude_code_session() -> Any:
    """Unregister a live claude-commander session."""
    body = request.get_json(silent=True) or {}
    socket_path = str(body.get("socket_path") or "").strip() or None
    claude_commander.unregister_session(socket_path)
    return jsonify({"ok": True})


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
    _save_screenshot(row)
    _prune_screenshots()
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

    coordinate_snapshot = body.get("coordinate_snapshot")
    if not isinstance(coordinate_snapshot, dict):
        coordinate_snapshot = None

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
        app.logger.error(
            "proactive_describe failed screenshot_id=%s device_id=%s session_id=%s error=%s\n%s",
            screenshot_id,
            row.get("device_id"),
            row.get("session_id"),
            str(exc),
            traceback.format_exc(),
        )
        fallback_raw = previous_description or {
            "schema_version": "1.0",
            "scene_summary": "",
            "problem_to_solve": "",
            "task_objective": "",
            "success_criteria": [],
            "canvas_state": {
                "is_blank": False,
                "density": "low",
                "primary_mode": "unknown",
            },
            "regions": [],
            "suggestion_candidates": [],
            "change_assessment": {
                "novelty_vs_previous": 0.0,
                "notable_changes": [],
            },
        }
        description = agent_module._normalize_proactive_description(fallback_raw)

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
    _delete_screenshot_row(row)
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
# Agent helpers
# ---------------------------------------------------------------------------

_ipad_place_log = logging.getLogger("iris.ipad_place")


def _request_source_ip() -> str:
    """Best-effort request source IP (supports simple proxy forwarding)."""
    forwarded = request.headers.get("X-Forwarded-For", "").strip()
    if forwarded:
        return forwarded.split(",")[0].strip()
    return (request.remote_addr or "").strip()


def _candidate_ipad_urls(source_ip: str | None = None) -> list[str]:
    """Build candidate iPad base URLs in priority order."""
    urls: list[str] = []
    ip = (source_ip or "").strip()
    if ip:
        host = ip
        # Bracket IPv6 literals for URL safety.
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        urls.append(f"http://{host}:8935")
        if ip in {"127.0.0.1", "::1", "localhost"}:
            urls.append("http://localhost:8935")
    urls.append(IRIS_IPAD_URL.rstrip("/"))
    # Deduplicate while preserving order.
    seen: set[str] = set()
    out: list[str] = []
    for url in urls:
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


def _post_ipad_place(
    svg: str,
    widget_record: dict[str, Any],
    *,
    ipad_base_urls: list[str] | None = None
) -> bool:
    """POST raw SVG to the iPad place endpoint (rasterized image). Returns True on first success."""
    payload = json.dumps({
        "svg": svg,
        "scale": 1.5,
        "x": widget_record.get("x", 0),
        "y": widget_record.get("y", 0),
        "coordinate_space": widget_record.get("coordinate_space", "viewport_offset"),
    }).encode("utf-8")
    bases = ipad_base_urls or [IRIS_IPAD_URL.rstrip("/")]
    for base in bases:
        url = f"{base.rstrip('/')}/api/v1/place"
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                _ipad_place_log.info("iPad place OK via %s (%s): %s", base, resp.status, resp.read(256))
            return True
        except Exception as exc:
            _ipad_place_log.warning("iPad place failed via %s: %s", base, exc)
    _ipad_place_log.warning("iPad place failed on all candidates; falling back to widget.open")
    return False


def _log_widget_push_debug(
    *,
    session_id: str,
    request_id: str,
    model: str,
    widget_record: dict[str, Any],
    raw_widget: dict[str, Any],
    event_kind: str,
    place_attempted: bool,
    place_succeeded: bool,
) -> None:
    """Emit a single structured debug line for each widget dispatch."""
    html = str(widget_record.get("html") or "")
    svg = str(widget_record.get("svg") or "")
    payload = {
        "type": "widget_push_debug",
        "session_id": session_id,
        "request_id": request_id,
        "model": model,
        "event_kind": event_kind,
        "place_attempted": place_attempted,
        "place_succeeded": place_succeeded,
        "widget": {
            "id": widget_record.get("id"),
            "type": widget_record.get("type"),
            "target": widget_record.get("target"),
            "coordinate_space": widget_record.get("coordinate_space"),
            "anchor": widget_record.get("anchor"),
            "x": widget_record.get("x"),
            "y": widget_record.get("y"),
            "width": widget_record.get("width"),
            "height": widget_record.get("height"),
            "has_html": bool(html),
            "html_len": len(html),
            "has_svg": bool(svg),
            "svg_len": len(svg),
        },
        "raw_widget_keys": sorted(raw_widget.keys()),
    }
    app.logger.info("widget_push_debug %s", json.dumps(payload, ensure_ascii=False))


def _wants_stream_response(body: dict[str, Any]) -> bool:
    stream_flag = str(request.args.get("stream", "")).strip().lower()
    if stream_flag in {"1", "true", "yes", "on"}:
        return True
    if isinstance(body.get("stream"), bool) and body.get("stream"):
        return True
    accept = (request.headers.get("Accept") or "").lower()
    return "text/event-stream" in accept


def _iter_text_chunks(text: str, size: int = 80) -> list[str]:
    if not text:
        return []
    chunk_size = max(1, size)
    return [text[i:i + chunk_size] for i in range(0, len(text), chunk_size)]


def _sse_event(event: str, payload: dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


def _finalize_agent_response(payload: dict[str, Any], *, stream: bool) -> Any:
    if not stream:
        return jsonify(payload)

    @stream_with_context
    def generate() -> Any:
        yield _sse_event("status", {"state": "running"})
        for chunk in _iter_text_chunks(str(payload.get("text") or "")):
            yield _sse_event("delta", {"text": chunk})
        yield _sse_event("final", payload)
        yield _sse_event("done", {"ok": True})

    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
    }
    return Response(generate(), mimetype="text/event-stream", headers=headers)


# ---------------------------------------------------------------------------
# Screenshot capture at query time
# ---------------------------------------------------------------------------

_screenshot_log = logging.getLogger("iris.screenshots")


def _capture_mac_screenshot() -> bytes | None:
    """Capture Mac screen via screencapture CLI. Returns JPEG bytes or None."""
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        subprocess.run(
            ["/usr/sbin/screencapture", "-x", "-t", "jpg", tmp_path],
            check=True,
            capture_output=True,
            timeout=4,
        )
        data = Path(tmp_path).read_bytes()
        if len(data) > 0:
            return data
        return None
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError) as exc:
        _screenshot_log.warning("Mac screenshot failed: %s", exc)
        return None
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def _capture_ipad_screenshot(source_ip: str | None = None) -> bytes | None:
    """Fetch screenshot from iPad HTTP server. Returns JPEG bytes or None."""
    urls = _candidate_ipad_urls(source_ip)
    for base in urls:
        url = f"{base.rstrip('/')}/api/v1/screenshot"
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=4) as resp:
                data = resp.read()
                if len(data) > 0:
                    _screenshot_log.info("iPad screenshot captured via %s (%d bytes)", base, len(data))
                    return data
        except Exception as exc:
            _screenshot_log.warning("iPad screenshot failed via %s: %s", base, exc)
    return None


def _capture_screenshots(source_ip: str | None = None) -> dict[str, bytes]:
    """Capture Mac and iPad screenshots in parallel. Returns dict with 'mac' and/or 'ipad' keys."""
    result: dict[str, bytes] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        mac_future = pool.submit(_capture_mac_screenshot)
        ipad_future = pool.submit(_capture_ipad_screenshot, source_ip)

        mac_data = mac_future.result(timeout=6)
        ipad_data = ipad_future.result(timeout=6)

    if mac_data:
        result["mac"] = mac_data
        _screenshot_log.info("Mac screenshot: %d bytes", len(mac_data))
    if ipad_data:
        result["ipad"] = ipad_data
        _screenshot_log.info("iPad screenshot: %d bytes", len(ipad_data))

    return result


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

@app.post("/v1/agent")
def v1_agent() -> Any:
    body = request.get_json(silent=True) or {}
    request_id = str(body.get("request_id") or "")
    stream_requested = _wants_stream_response(body)

    session_id = (body.get("session_id") or "").strip()
    if not session_id:
        return jsonify({"error": "session_id is required"}), 400

    input_data = body.get("input") or {}
    if input_data.get("type") != "text":
        return jsonify({"error": "input.type must be 'text'"}), 400
    message = (input_data.get("text") or "").strip()
    if not message:
        return jsonify({"error": "input.text is required"}), 400

    model = (body.get("model") or "").strip() or "gpt-5.2-mini"
    device = body.get("device") or {}
    request_metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
    ephemeral = bool(request_metadata.get("ephemeral"))

    session: dict[str, Any] | None = None
    context: list[dict[str, str]] = []

    is_first_prompt = False

    if not ephemeral:
        # Load or create session
        session = _load_session(session_id)
        if not session:
            session = _make_session(session_id, session_id, model)
        if not isinstance(session.get("metadata"), dict):
            session["metadata"] = {}
        metadata = session["metadata"]
        is_first_prompt = not session.get("messages") and _session_needs_auto_name(session)
        needs_claude_bootstrap = not session.get("messages")

        # Merge provider-link metadata from request into persisted session metadata.
        conversation_id = request_metadata.get("claude_code_conversation_id")
        if isinstance(conversation_id, str) and conversation_id.strip():
            metadata["claude_code_conversation_id"] = conversation_id.strip()
        claude_code_cwd = request_metadata.get("claude_code_cwd")
        if isinstance(claude_code_cwd, str) and claude_code_cwd.strip():
            metadata["claude_code_cwd"] = claude_code_cwd.strip()
        codex_conversation_id = request_metadata.get("codex_conversation_id")
        if isinstance(codex_conversation_id, str) and codex_conversation_id.strip():
            metadata["codex_conversation_id"] = codex_conversation_id.strip()
        codex_cwd = request_metadata.get("codex_cwd")
        if isinstance(codex_cwd, str) and codex_cwd.strip():
            metadata["codex_cwd"] = codex_cwd.strip()
        system_prompt = _iris_system_prompt()
        if system_prompt:
            metadata["system_prompt"] = system_prompt

        session["model"] = model

        claude_code_mode = model.strip().lower() == "claude_code" or bool(
            str(metadata.get("claude_code_conversation_id") or "").strip()
        )
        if claude_code_mode:
            session["model"] = "claude_code"
            live = claude_commander.get_live_session()
            if not live:
                return jsonify({
                    "error": "No live session. Run `claudei` in your project on the Mac.",
                }), 503

            socket_path = live.get("socket_path", claude_commander.DEFAULT_SOCKET_PATH)
            message_for_claude = message
            if needs_claude_bootstrap:
                bootstrap = _iris_claude_cli_bootstrap_prompt()
                if bootstrap:
                    message_for_claude = (
                        f"{bootstrap}\n\n"
                        f"User request:\n{message}"
                    )
            image_b64 = (body.get("image_base64") or "").strip()
            if image_b64:
                ok = claude_commander.inject_image(
                    image_base64=image_b64,
                    prompt=message_for_claude,
                    socket_path=socket_path,
                )
            else:
                ok = claude_commander.inject_text(message_for_claude, socket_path)
            if not ok:
                return jsonify({"error": "Failed to inject into live session"}), 502
            claude_commander.mark_busy()

            # Store user message so it appears on all devices via SSE/polling
            user_ts = _now()
            user_msg = {
                "id": str(uuid.uuid4()),
                "role": "user",
                "content": message,
                "created_at": user_ts,
                "device_id": device.get("id"),
                "source": "agent.v1",
            }
            session.setdefault("messages", []).append(user_msg)
            session["updated_at"] = user_ts

            if is_first_prompt:
                _auto_name_session(session, message)
            _save_session(session)
            _publish_messages(session_id, [user_msg])
            return _finalize_agent_response(
                {
                    "kind": "message.final",
                    "request_id": request_id,
                    "session_id": session_id,
                    "session_name": session.get("name", ""),
                    "model": "claude_code",
                    "mode": "live",
                    "text": "(sent to live Claude Code session)",
                    "events": [],
                    "timestamp": _now(),
                },
                stream=stream_requested,
            )

        codex_mode = model.strip().lower() == "codex" or bool(
            str(metadata.get("codex_conversation_id") or "").strip()
        )
        if codex_mode:
            session["model"] = "codex"
            try:
                linked_result = _execute_linked_provider(
                    session,
                    provider="codex",
                    prompt=message,
                    device_id=device.get("id"),
                    source_suffix="v1",
                )
            except ValueError as exc:
                return jsonify({"error": str(exc)}), 400
            except RuntimeError as exc:
                return jsonify({"error": str(exc)}), 502

            if is_first_prompt:
                _auto_name_session(session, message)
            _save_session(session)
            return _finalize_agent_response(
                {
                    "kind": "message.final",
                    "request_id": request_id,
                    "session_id": session_id,
                    "session_name": session.get("name", ""),
                    "model": "codex",
                    "text": linked_result["text"],
                    "events": [],
                    "timestamp": _now(),
                },
                stream=stream_requested,
            )

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
        user_ts = _now()
        user_msg = {
            "id": str(uuid.uuid4()),
            "role": "user",
            "content": message,
            "created_at": user_ts,
            "device_id": device.get("id"),
            "source": "agent.v1",
        }
        session.setdefault("messages", []).append(user_msg)
        _save_session(session)
        _publish_messages(session_id, [user_msg])
    else:
        recent = (body.get("context") or {}).get("recent_messages") or []
        for msg in recent[-20:]:
            role = (msg.get("role") or "").strip()
            text = (msg.get("text") or "").strip()
            if role in ("user", "assistant") and text:
                context.append({"role": role, "content": text})

    # Capture screenshots from both devices at query time.
    source_ip = _request_source_ip()
    try:
        screenshots = _capture_screenshots(source_ip)
    except Exception as exc:
        _screenshot_log.warning("Screenshot capture failed: %s", exc)
        screenshots = {}

    # Call agent with optional spatial context from caller metadata.
    enriched_message = message
    spatial_note = _spatial_context_text(request_metadata)
    if spatial_note:
        enriched_message = f"{message}\n\n{spatial_note}"
    try:
        result = agent_module.run(context, enriched_message, model=model, screenshots=screenshots)
    except Exception as exc:
        app.logger.error(
            "v1_agent failed session_id=%s model=%s ephemeral=%s error=%s\n%s",
            session_id,
            model,
            ephemeral,
            str(exc),
            traceback.format_exc(),
        )
        return jsonify(
            {
                "error": "agent_failed",
                "message": str(exc),
                "session_id": session_id,
                "model": model,
                "timestamp": _now(),
            }
        ), 502

    # Persist assistant response only for non-ephemeral requests.
    ts = _now()
    if not ephemeral and session is not None:
        assistant_msg: dict[str, Any] = {
            "id": str(uuid.uuid4()),
            "role": "assistant",
            "content": result["text"],
            "created_at": ts,
            "device_id": None,
            "source": "agent.v1",
        }
        if result.get("tool_calls"):
            assistant_msg["tool_calls"] = result["tool_calls"]
        session["messages"].append(assistant_msg)
        _publish_messages(session_id, [assistant_msg])

    # Emit tool.call/tool.result events + store widgets in session
    events: list[dict] = []
    for tc in result.get("tool_calls", []):
        tool_name = str(tc.get("name") or "unknown")
        events.append({
            "kind": "tool.call",
            "name": tool_name,
            "input": {k: v for k, v in tc.items() if k != "name"},
        })
        if "result" in tc or "ok" in tc:
            tool_result_event: dict[str, Any] = {
                "kind": "tool.result",
                "name": tool_name,
            }
            result_payload = tc.get("result")
            if "result" in tc:
                tool_result_event["result"] = result_payload
            ok_value: Any = tc.get("ok")
            if ok_value is None and isinstance(result_payload, dict) and "ok" in result_payload:
                ok_value = result_payload.get("ok")
            if ok_value is not None:
                tool_result_event["ok"] = bool(ok_value)
            events.append(tool_result_event)
    for w in result.get("widgets", []):
        widget_record = {
            "id": w.get("widget_id", str(uuid.uuid4())),
            "type": w.get("type", "html"),
            "html": w.get("html", ""),
            "target": w.get("target", "mac"),
            "width": w.get("width", 320),
            "height": w.get("height", 220),
            "x": w.get("x", 0),
            "y": w.get("y", 0),
            "coordinate_space": w.get("coordinate_space", "viewport_offset"),
            "anchor": w.get("anchor", "top_left"),
            "created_at": ts,
        }
        raw_svg = w.get("svg")
        if raw_svg:
            widget_record["svg"] = raw_svg

        app.logger.info(
            "widget_push session_id=%s model=%s target=%s id=%s coordinate_space=%s anchor=%s widget_xy=(%s,%s) widget_size=(%s,%s) %s",
            session_id,
            model,
            widget_record["target"],
            widget_record["id"],
            widget_record["coordinate_space"],
            widget_record["anchor"],
            widget_record["x"],
            widget_record["y"],
            widget_record["width"],
            widget_record["height"],
            _fov_summary_from_metadata(request_metadata),
        )
        if not ephemeral and session is not None:
            session.setdefault("widgets", []).append(widget_record)

        # Route iPad diagrams to the place endpoint (rasterized SVG image).
        # Never fall through to widget.open — iPad diagrams are always rasterized.
        is_ipad_diagram = (
            widget_record["type"] == "diagram"
            and widget_record["target"] == "ipad"
            and raw_svg
        )
        place_attempted = False
        place_succeeded = False
        if is_ipad_diagram:
            place_attempted = True
            source_ip = _request_source_ip()
            place_ok = _post_ipad_place(
                raw_svg,
                widget_record,
                ipad_base_urls=_candidate_ipad_urls(source_ip),
            )
            place_succeeded = place_ok
            _log_widget_push_debug(
                session_id=session_id,
                request_id=request_id,
                model=model,
                widget_record=widget_record,
                raw_widget=w,
                event_kind="place" if place_ok else "place_failed",
                place_attempted=place_attempted,
                place_succeeded=place_succeeded,
            )
            if place_ok:
                events.append({
                    "kind": "place",
                    "place": {
                        "id": widget_record["id"],
                        "target": widget_record["target"],
                        "svg": raw_svg,
                        "x": widget_record["x"],
                        "y": widget_record["y"],
                        "coordinate_space": widget_record["coordinate_space"],
                    },
                })
            continue

        _log_widget_push_debug(
            session_id=session_id,
            request_id=request_id,
            model=model,
            widget_record=widget_record,
            raw_widget=w,
            event_kind="widget.open",
            place_attempted=place_attempted,
            place_succeeded=place_succeeded,
        )
        events.append({
            "kind": "widget.open",
            "widget": {
                "kind": "html",
                "id": widget_record["id"],
                "target": widget_record["target"],
                "payload": {"html": widget_record["html"]},
                "width": widget_record["width"],
                "height": widget_record["height"],
                "x": widget_record["x"],
                "y": widget_record["y"],
                "coordinate_space": widget_record["coordinate_space"],
                "anchor": widget_record["anchor"],
            },
        })

    if not ephemeral and session is not None:
        if is_first_prompt:
            _auto_name_session(session, message)
        session["updated_at"] = ts
        _save_session(session)

    return _finalize_agent_response(
        {
            "kind": "message.final",
            "request_id": request_id,
            "session_id": session_id,
            "session_name": session.get("name", "") if session else "",
            "model": model,
            "text": result["text"],
            "events": events,
            "timestamp": _now(),
        },
        stream=stream_requested,
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port, debug=True)

"""Lightweight Claude Commander bridge used by backend/app.py.

This module tracks a live local UNIX socket session and can inject text/image
messages into a running commander-compatible process.
"""
from __future__ import annotations

import base64
import json
import os
import socket
import tempfile
import time
from pathlib import Path
from typing import Any

DEFAULT_SOCKET_PATH = "/tmp/iris-claude.sock"
_SESSION_STATE_PATH = Path("/tmp/iris-claude-session.json")

_live_session: dict[str, Any] | None = None
_is_idle = True


def _persist_state() -> None:
    if not _live_session:
        _SESSION_STATE_PATH.unlink(missing_ok=True)
        return
    payload = {
        "socket_path": _live_session.get("socket_path") or DEFAULT_SOCKET_PATH,
        "cwd": _live_session.get("cwd"),
        "pid": _live_session.get("pid"),
        "updated_at": int(time.time()),
    }
    _SESSION_STATE_PATH.write_text(json.dumps(payload), encoding="utf-8")


def _load_state() -> dict[str, Any] | None:
    global _live_session
    if _live_session:
        return _live_session
    try:
        raw = json.loads(_SESSION_STATE_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(raw, dict):
        return None
    socket_path = str(raw.get("socket_path") or "").strip() or DEFAULT_SOCKET_PATH
    session = {
        "socket_path": socket_path,
        "cwd": str(raw.get("cwd") or "").strip() or None,
        "pid": raw.get("pid"),
    }
    _live_session = session
    return session


def _send_json_payload(
    socket_path: str,
    payload: dict[str, Any],
    *,
    allow_silent_success: bool,
) -> bool:
    path = Path(socket_path)
    if not path.exists():
        return False

    encoded = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2.0)
            client.connect(str(path))
            client.sendall(encoded)

            # Newer claudec-iris endpoints return an explicit JSON ack; legacy
            # commander variants may not return any data before close.
            try:
                client.settimeout(0.35)
                raw = client.recv(4096)
            except socket.timeout:
                return allow_silent_success

            if not raw:
                return allow_silent_success

            first_line = raw.decode("utf-8", errors="replace").strip().splitlines()[0]
            try:
                reply = json.loads(first_line)
            except json.JSONDecodeError:
                return allow_silent_success

            if isinstance(reply, dict) and str(reply.get("error") or "").strip():
                return False
            return True
    except OSError:
        return False


def _send_plain_text(socket_path: str, text: str) -> bool:
    path = Path(socket_path)
    if not path.exists():
        return False
    wire = (text + "\n").encode("utf-8")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2.0)
            client.connect(str(path))
            client.sendall(wire)
            return True
    except OSError:
        return False


def register_session(socket_path: str, cwd: str | None = None, pid: int | None = None) -> None:
    global _live_session
    socket_path = str(socket_path or "").strip() or DEFAULT_SOCKET_PATH
    _live_session = {
        "socket_path": socket_path,
        "cwd": str(cwd).strip() if isinstance(cwd, str) and cwd.strip() else None,
        "pid": pid,
    }
    _persist_state()


def unregister_session(socket_path: str | None = None) -> None:
    global _live_session
    if socket_path:
        current = get_live_session()
        if current and str(current.get("socket_path") or "") != str(socket_path):
            return
    _live_session = None
    _persist_state()


def get_live_session() -> dict[str, Any] | None:
    session = _load_state()
    if not session:
        return None
    socket_path = str(session.get("socket_path") or DEFAULT_SOCKET_PATH)
    if not is_connected(socket_path):
        return None
    return {
        "socket_path": socket_path,
        "cwd": session.get("cwd"),
        "pid": session.get("pid"),
    }


def is_connected(socket_path: str | None = None) -> bool:
    path = Path(str(socket_path or DEFAULT_SOCKET_PATH))
    if not path.exists():
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1.5)
            client.connect(str(path))
            return True
    except OSError:
        return False


def inject_text(text: str, socket_path: str | None = None) -> bool:
    message = str(text or "").strip()
    if not message:
        return False
    resolved_socket = str(socket_path or DEFAULT_SOCKET_PATH)

    # Legacy claude-commander payload format.
    legacy_payload = {"type": "text", "text": message, "prompt": message}
    if _send_json_payload(resolved_socket, legacy_payload, allow_silent_success=True):
        return True

    # claudec-iris payload format.
    modern_payload = {"action": "send", "text": message, "submit": True}
    if _send_json_payload(resolved_socket, modern_payload, allow_silent_success=False):
        return True

    # Last-resort compatibility for simple plaintext socket writers.
    return _send_plain_text(resolved_socket, message)


def inject_image(
    *,
    image_path: str | None = None,
    image_base64: str | None = None,
    prompt: str | None = None,
    socket_path: str | None = None,
) -> bool:
    chosen_path: str | None = None

    if image_path:
        p = Path(image_path).expanduser().resolve()
        if p.is_file():
            chosen_path = str(p)

    if not chosen_path and image_base64:
        try:
            raw = base64.b64decode(image_base64)
        except (ValueError, TypeError):
            raw = b""
        if raw:
            tmp = tempfile.NamedTemporaryFile(prefix="iris-image-", suffix=".png", delete=False)
            with tmp:
                tmp.write(raw)
            chosen_path = tmp.name

    if not chosen_path:
        return False

    text_prompt = str(prompt or "").strip()
    resolved_socket = str(socket_path or DEFAULT_SOCKET_PATH)
    legacy_payload = {
        "type": "image",
        "image_path": chosen_path,
        "prompt": text_prompt,
        "text": text_prompt,
    }
    if _send_json_payload(resolved_socket, legacy_payload, allow_silent_success=True):
        return True

    message = f"[Iris: Image from iPad at {chosen_path} — use Read tool to view it]"
    if text_prompt:
        message = f"{message}\n{text_prompt}"
    return inject_text(message, socket_path=resolved_socket)


def mark_busy() -> None:
    global _is_idle
    _is_idle = False


def mark_idle() -> None:
    global _is_idle
    _is_idle = True


def is_idle() -> bool:
    return _is_idle


def get_status(socket_path: str | None = None) -> dict[str, Any]:
    session = _load_state() or {}
    resolved_path = str(socket_path or session.get("socket_path") or DEFAULT_SOCKET_PATH)
    connected = is_connected(resolved_path)
    return {
        "socket_path": resolved_path,
        "connected": connected,
        "idle": _is_idle,
        "session_registered": bool(session),
    }

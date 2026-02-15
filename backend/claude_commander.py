"""Iris ↔ claude-commander socket injection module.

Communicates with a running claude-commander instance via Unix socket to inject
text and image references into a live Claude Code session.

Protocol: newline-delimited JSON over Unix domain socket.
  Send:   {"action": "send", "text": "...", "submit": true}
  Status: {"action": "status"}
"""
from __future__ import annotations

import base64
import json
import logging
import os
import socket
import time
import uuid
from pathlib import Path
from typing import Any

log = logging.getLogger("iris.claude_commander")

DEFAULT_SOCKET_PATH = "/tmp/iris-claude.sock"
META_FILE = "/tmp/iris-claude-meta.json"
IMAGES_DIR = Path("/tmp/iris/images")

# ---------------------------------------------------------------------------
# Low-level socket helpers
# ---------------------------------------------------------------------------

def _send_command(command: dict[str, Any], socket_path: str = DEFAULT_SOCKET_PATH, timeout: float = 5.0) -> dict[str, Any] | None:
    """Send a JSON command to the claude-commander socket and return the response."""
    if not os.path.exists(socket_path):
        log.warning("Socket not found: %s", socket_path)
        return None

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(socket_path)

        payload = json.dumps(command) + "\n"
        sock.sendall(payload.encode("utf-8"))

        # Read response (may not always get one for "send" actions)
        chunks: list[bytes] = []
        try:
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
                # Check if we got a complete JSON line
                combined = b"".join(chunks)
                if b"\n" in combined:
                    break
        except socket.timeout:
            pass

        sock.close()

        if chunks:
            raw = b"".join(chunks).decode("utf-8").strip()
            if raw:
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    log.debug("Non-JSON response: %s", raw[:200])
                    return {"raw": raw}
        return {"ok": True}

    except (OSError, ConnectionRefusedError) as exc:
        log.warning("Socket communication failed (%s): %s", socket_path, exc)
        return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def is_connected(socket_path: str = DEFAULT_SOCKET_PATH) -> bool:
    """Check if a claude-commander socket exists and responds."""
    if not os.path.exists(socket_path):
        return False
    result = _send_command({"action": "status"}, socket_path, timeout=2.0)
    return result is not None


def get_status(socket_path: str = DEFAULT_SOCKET_PATH) -> dict[str, Any]:
    """Get status from the claude-commander instance."""
    if not os.path.exists(socket_path):
        return {"connected": False, "error": "socket not found"}

    result = _send_command({"action": "status"}, socket_path, timeout=2.0)
    if result is None:
        return {"connected": False, "error": "no response"}

    result["connected"] = True
    return result


def get_meta() -> dict[str, Any] | None:
    """Read the session meta file written by tools/iris-session."""
    try:
        return json.loads(Path(META_FILE).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def inject_text(text: str, socket_path: str = DEFAULT_SOCKET_PATH, submit: bool = True) -> bool:
    """Inject a text message into the live Claude Code session.

    Args:
        text: The message to inject (appears as user input).
        socket_path: Path to the claude-commander Unix socket.
        submit: If True, the message is submitted immediately (Enter pressed).

    Returns:
        True if the message was sent successfully.
    """
    if not text.strip():
        log.warning("inject_text called with empty text")
        return False

    result = _send_command(
        {"action": "send", "text": text, "submit": submit},
        socket_path,
    )
    if result is None:
        log.error("inject_text failed: socket not responding")
        return False

    log.info("inject_text OK: %d chars, submit=%s", len(text), submit)
    return True


def inject_image(
    image_path: str | None = None,
    image_base64: str | None = None,
    prompt: str = "",
    socket_path: str = DEFAULT_SOCKET_PATH,
) -> bool:
    """Inject an image reference into the live Claude Code session.

    The image is saved to /tmp/iris/images/ and a text message is injected
    telling Claude Code to use its Read tool to view the image.

    Args:
        image_path: Path to an existing image file.
        image_base64: Base64-encoded image data (saved to a new file).
        prompt: Additional prompt/instructions to include with the image.
        socket_path: Path to the claude-commander Unix socket.

    Returns:
        True if the injection succeeded.
    """
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    if image_base64:
        # Decode and save to a new file
        ts = int(time.time() * 1000)
        dest = IMAGES_DIR / f"{ts}_{uuid.uuid4().hex[:8]}.png"
        try:
            dest.write_bytes(base64.b64decode(image_base64))
        except Exception as exc:
            log.error("Failed to decode base64 image: %s", exc)
            return False
        image_path = str(dest)
    elif image_path:
        if not Path(image_path).exists():
            log.error("Image file not found: %s", image_path)
            return False
    else:
        log.error("inject_image requires either image_path or image_base64")
        return False

    # Build the injection text
    parts = [f"[Iris: Image from iPad at {image_path} — use Read tool to view it]"]
    if prompt.strip():
        parts.append(prompt.strip())
    else:
        parts.append("Please describe what you see in this image and use it as context.")

    message = "\n".join(parts)
    return inject_text(message, socket_path)


# ---------------------------------------------------------------------------
# Live session state tracking
# ---------------------------------------------------------------------------

_live_session: dict[str, Any] = {}


def register_session(socket_path: str, cwd: str | None = None, pid: int | None = None) -> None:
    """Register a live claude-commander session (called by tools/iris-session)."""
    _live_session.update({
        "socket_path": socket_path,
        "cwd": cwd,
        "pid": pid,
        "registered_at": time.time(),
    })
    log.info("Live session registered: socket=%s cwd=%s pid=%s", socket_path, cwd, pid)


def unregister_session(socket_path: str | None = None) -> None:
    """Unregister the live session."""
    _live_session.clear()
    log.info("Live session unregistered")


def get_live_session() -> dict[str, Any] | None:
    """Return the currently registered live session info, or None."""
    if not _live_session:
        # Fall back to checking the meta file
        meta = get_meta()
        if meta and is_connected(meta.get("socket_path", DEFAULT_SOCKET_PATH)):
            return meta
        return None

    # Verify it's still alive
    sp = _live_session.get("socket_path", DEFAULT_SOCKET_PATH)
    if not is_connected(sp):
        log.info("Live session no longer responding, clearing registration")
        _live_session.clear()
        return None

    return dict(_live_session)


# ---------------------------------------------------------------------------
# Idle tracking (set by Stop hook, consumed by injection)
# ---------------------------------------------------------------------------

_idle_flag = False


def mark_idle() -> None:
    """Mark Claude Code as idle (called by the Stop hook)."""
    global _idle_flag
    _idle_flag = True
    log.debug("Claude Code marked idle")


def mark_busy() -> None:
    """Mark Claude Code as busy (called after injection)."""
    global _idle_flag
    _idle_flag = False


def is_idle() -> bool:
    """Check if Claude Code is idle and ready for injection."""
    return _idle_flag

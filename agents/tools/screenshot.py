from __future__ import annotations

import base64
from pathlib import Path

import httpx

BACKEND_SCREENSHOTS_DIR = Path(__file__).resolve().parent.parent.parent / "backend" / "data" / "screenshots"
BACKEND_URL = "http://localhost:5000"

READ_SCREENSHOT_TOOL = {
    "type": "function",
    "function": {
        "name": "read_screenshot",
        "description": "Read the latest screenshot from a device. Returns the image as base64-encoded data.",
        "parameters": {
            "type": "object",
            "properties": {
                "device": {
                    "type": "string",
                    "enum": ["mac", "ipad"],
                    "description": "The device whose latest screenshot to read.",
                },
            },
            "required": ["device"],
        },
    },
}


def handle_read_screenshot(
    arguments: dict, context: dict
) -> tuple[str, None]:
    device = arguments["device"]
    session_id = context.get("session_id")

    # Session-scoped: fetch from backend API
    if session_id:
        try:
            resp = httpx.get(
                f"{BACKEND_URL}/api/screenshots",
                params={"session_id": session_id},
                timeout=5,
            )
            if resp.status_code == 200:
                screenshots = resp.json()
                if screenshots:
                    latest = screenshots[0]
                    file_path = Path(latest["file_path"])
                    if file_path.exists():
                        data = base64.b64encode(file_path.read_bytes()).decode()
                        suffix = file_path.suffix.lstrip(".")
                        mime = f"image/{suffix}" if suffix in ("png", "jpeg", "jpg", "gif", "webp") else "application/octet-stream"
                        return f"Latest screenshot (session {session_id}): {file_path.name} ({mime}, {len(data)} bytes base64)", None
                return f"No screenshots available for session {session_id}.", None
        except httpx.HTTPError:
            return f"Failed to fetch screenshots for session {session_id} from backend.", None

    # Fallback: read from filesystem directory (mac / general)
    if not BACKEND_SCREENSHOTS_DIR.exists():
        return f"No screenshots directory found for {device}.", None

    image_files = sorted(
        BACKEND_SCREENSHOTS_DIR.glob("**/*"),
        key=lambda p: p.stat().st_mtime if p.is_file() else 0,
        reverse=True,
    )
    image_files = [f for f in image_files if f.is_file()]

    if not image_files:
        return f"No screenshots available for {device}.", None

    latest = image_files[0]
    data = base64.b64encode(latest.read_bytes()).decode()
    suffix = latest.suffix.lstrip(".")
    mime = f"image/{suffix}" if suffix in ("png", "jpeg", "jpg", "gif", "webp") else "application/octet-stream"

    return f"Latest screenshot from {device}: {latest.name} ({mime}, {len(data)} bytes base64)", None

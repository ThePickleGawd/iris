from __future__ import annotations

import base64

import httpx

import os
from datetime import datetime, timezone

BACKEND_URL = os.environ.get("IRIS_BACKEND_URL", "http://localhost:5050")

READ_SCREENSHOT_TOOL = {
    "type": "function",
    "function": {
        "name": "read_screenshot",
        "description": "Read the latest screenshot from a device. Returns the image as base64-encoded data that you can see.",
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
) -> tuple[str | list, None]:
    """Fetch the latest screenshot and return it as a multimodal content block.

    Returns a list of content blocks (text + image_url) when an image is
    available so the LLM can actually *see* the screenshot.  Falls back
    to a plain text message when nothing is found.
    """
    device = arguments["device"]
    session_id = context.get("session_id")

    # Try session-scoped first, then fall back to device-scoped.
    params: dict[str, str] = {}
    used_session_scope = False
    if session_id:
        params["session_id"] = session_id
        used_session_scope = True
    else:
        params["device_id"] = device

    def _to_dt(value: object) -> datetime:
        if not isinstance(value, str) or not value.strip():
            return datetime.fromtimestamp(0, tz=timezone.utc)
        normalized = value.strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            return datetime.fromtimestamp(0, tz=timezone.utc)
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    try:
        resp = httpx.get(
            f"{BACKEND_URL}/api/screenshots",
            params=params,
            timeout=5,
        )
        if resp.status_code != 200:
            return f"Failed to list screenshots from backend (HTTP {resp.status_code}).", None

        data = resp.json()
        # Backend returns either a list (session query) or {"items": [...]} (paginated)
        screenshots = data if isinstance(data, list) else data.get("items", [])
        if not screenshots and used_session_scope:
            fallback_resp = httpx.get(
                f"{BACKEND_URL}/api/screenshots",
                params={"device_id": device},
                timeout=5,
            )
            if fallback_resp.status_code == 200:
                fallback_data = fallback_resp.json()
                screenshots = (
                    fallback_data if isinstance(fallback_data, list)
                    else fallback_data.get("items", [])
                )

        if not screenshots:
            return f"No screenshots available for {device}.", None

        # Always pick newest by timestamp and skip stale file rows (e.g. 410 Gone).
        ordered = sorted(
            screenshots,
            key=lambda row: (
                _to_dt(row.get("captured_at") or row.get("created_at")),
                _to_dt(row.get("created_at")),
                str(row.get("id", "")),
            ),
            reverse=True,
        )

        latest = None
        file_resp = None
        screenshot_id = ""
        for candidate in ordered:
            candidate_id = str(candidate.get("id", ""))
            if not candidate_id:
                continue
            candidate_resp = httpx.get(
                f"{BACKEND_URL}/api/screenshots/{candidate_id}/file",
                timeout=10,
            )
            if candidate_resp.status_code == 200:
                latest = candidate
                file_resp = candidate_resp
                screenshot_id = candidate_id
                break

        if latest is None or file_resp is None:
            status = "unknown"
            if ordered:
                fallback_id = str(ordered[0].get("id", ""))
                if fallback_id:
                    probe = httpx.get(
                        f"{BACKEND_URL}/api/screenshots/{fallback_id}/file",
                        timeout=10,
                    )
                    status = str(probe.status_code)
            return f"Screenshot metadata found but no readable screenshot file (last HTTP {status}).", None

        image_bytes = file_resp.content
        mime_type = latest.get("mime_type", "image/png")
        b64_data = base64.b64encode(image_bytes).decode()

        notes = latest.get("notes")
        notes_text = ""
        if isinstance(notes, str) and notes.strip():
            notes_text = f"\n\nCoordinate/context metadata from uploader:\n{notes.strip()}"

        # Return Anthropic-format multimodal content blocks so the LLM sees the image
        return [
            {
                "type": "text",
                "text": (
                    f"Latest screenshot from {device} "
                    f"(id={screenshot_id}, {len(image_bytes)} bytes):{notes_text}"
                ),
            },
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": mime_type,
                    "data": b64_data,
                },
            },
        ], None

    except httpx.HTTPError as exc:
        return f"Failed to fetch screenshots from backend: {exc}", None

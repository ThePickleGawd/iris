from __future__ import annotations

import base64

import httpx

import os

BACKEND_URL = os.environ.get("IRIS_BACKEND_URL", "http://localhost:5000")

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

        # Take the most recent one (session query is already DESC; paginated is ASC so take last)
        latest = screenshots[0] if session_id else screenshots[-1]

        # Fetch the actual image bytes via the file endpoint
        screenshot_id = latest["id"]
        file_resp = httpx.get(
            f"{BACKEND_URL}/api/screenshots/{screenshot_id}/file",
            timeout=10,
        )
        if file_resp.status_code != 200:
            return f"Screenshot metadata found but file fetch failed (HTTP {file_resp.status_code}).", None

        image_bytes = file_resp.content
        mime_type = latest.get("mime_type", "image/png")
        b64_data = base64.b64encode(image_bytes).decode()

        # Return Anthropic-format multimodal content blocks so the LLM sees the image
        return [
            {
                "type": "text",
                "text": f"Latest screenshot from {device} (id={screenshot_id}, {len(image_bytes)} bytes):",
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

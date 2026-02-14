from __future__ import annotations

import httpx

import os

BACKEND_URL = os.environ.get("IRIS_BACKEND_URL", "http://localhost:5000")

READ_TRANSCRIPT_TOOL = {
    "type": "function",
    "function": {
        "name": "read_transcript",
        "description": "Read recent voice transcripts from devices. Returns the text of recent speech-to-text transcriptions.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of recent transcripts to return. Default 10.",
                },
            },
        },
    },
}


def handle_read_transcript(
    arguments: dict, context: dict
) -> tuple[str, None]:
    limit = arguments.get("limit", 10)

    try:
        resp = httpx.get(
            f"{BACKEND_URL}/api/transcripts",
            params={"limit": str(limit)},
            timeout=5,
        )
        if resp.status_code != 200:
            return f"Failed to fetch transcripts (HTTP {resp.status_code}).", None

        data = resp.json()
        items = data.get("items", [])
        if not items:
            return "No transcripts available.", None

        lines = []
        for t in items:
            ts = t.get("captured_at", t.get("created_at", ""))
            device = t.get("device_id", "unknown")
            text = t.get("text", "")
            lines.append(f"[{ts}] ({device}) {text}")

        return "\n".join(lines), None

    except httpx.HTTPError as exc:
        return f"Failed to fetch transcripts: {exc}", None

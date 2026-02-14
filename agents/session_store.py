"""Filesystem-backed session store for CLI session IDs.

Persists {chat_id -> agent, cli_session_id} as JSON files so that
`--resume` / `--continue` survive agent server restarts.
"""
from __future__ import annotations

import json
from pathlib import Path

SESSIONS_DIR = Path(__file__).parent / "data" / "sessions"


def load(chat_id: str) -> dict | None:
    path = SESSIONS_DIR / f"{chat_id}.json"
    if path.exists():
        return json.loads(path.read_text())
    return None


def save(chat_id: str, agent: str, cli_session_id: str | None):
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    path = SESSIONS_DIR / f"{chat_id}.json"
    data = {"agent": agent, "cli_session_id": cli_session_id}
    path.write_text(json.dumps(data))

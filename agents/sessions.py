from __future__ import annotations

import logging
import os
import uuid

import httpx

logger = logging.getLogger(__name__)

BACKEND_URL = os.environ.get("IRIS_BACKEND_URL", "http://localhost:5001")

_store: dict[str, dict] = {}
_http: httpx.Client | None = None


def _client() -> httpx.Client:
    global _http
    if _http is None:
        _http = httpx.Client(base_url=BACKEND_URL, timeout=5.0)
    return _http


def _backend_post(path: str, json: dict) -> dict | None:
    """Fire-and-forget POST to backend. Returns response JSON or None on failure."""
    try:
        resp = _client().post(path, json=json)
        if resp.status_code < 300:
            return resp.json()
    except Exception as exc:
        logger.warning("Backend POST %s failed: %s", path, exc)
    return None


def _backend_get(path: str, params: dict | None = None) -> dict | None:
    """GET from backend. Returns response JSON or None on failure."""
    try:
        resp = _client().get(path, params=params)
        if resp.status_code < 300:
            return resp.json()
    except Exception as exc:
        logger.warning("Backend GET %s failed: %s", path, exc)
    return None


def get_or_create(chat_id: str, agent: str | None = None) -> dict:
    if chat_id in _store:
        session = _store[chat_id]
        if agent and session["agent"] != agent:
            session["agent"] = agent
        return session

    # Try hydrating from backend
    data = _backend_get(f"/api/sessions/{chat_id}")
    if data and "id" in data:
        # Hydrate messages too
        msg_data = _backend_get(f"/api/sessions/{chat_id}/messages", {"limit": "200"})
        messages = []
        if msg_data and "items" in msg_data:
            messages = [{"role": m["role"], "content": m["content"]} for m in msg_data["items"]]

        session = {
            "chat_id": chat_id,
            "agent": agent or data.get("agent", "iris"),
            "messages": messages,
        }
        _store[chat_id] = session
        return session

    # Create new session both locally and in backend
    session = {
        "chat_id": chat_id,
        "agent": agent or "iris",
        "messages": [],
    }
    _store[chat_id] = session

    _backend_post("/api/sessions", {
        "id": chat_id,
        "name": chat_id,
        "agent": agent or "iris",
    })

    return session


def add_message(chat_id: str, role: str, content: str) -> None:
    session = _store.get(chat_id)
    if session is None:
        session = get_or_create(chat_id)
    session["messages"].append({"role": role, "content": content})

    # Write through to backend (fire-and-forget)
    _backend_post(f"/api/sessions/{chat_id}/messages", {
        "id": str(uuid.uuid4()),
        "role": role,
        "content": content,
    })


def get_messages(chat_id: str) -> list[dict]:
    session = _store.get(chat_id)
    if session is None:
        # Try hydrating from backend
        msg_data = _backend_get(f"/api/sessions/{chat_id}/messages", {"limit": "200"})
        if msg_data and "items" in msg_data:
            return [{"role": m["role"], "content": m["content"]} for m in msg_data["items"]]
        return []
    return session["messages"]

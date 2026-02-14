from __future__ import annotations

_store: dict[str, dict] = {}


def get_or_create(chat_id: str, agent: str | None = None) -> dict:
    if chat_id not in _store:
        _store[chat_id] = {
            "chat_id": chat_id,
            "agent": agent,
            "messages": [],
        }
    session = _store[chat_id]
    if agent and session["agent"] != agent:
        session["agent"] = agent
    return session


def add_message(chat_id: str, role: str, content: str) -> None:
    session = _store.get(chat_id)
    if session is None:
        session = get_or_create(chat_id)
    session["messages"].append({"role": role, "content": content})


def get_messages(chat_id: str) -> list[dict]:
    session = _store.get(chat_id)
    if session is None:
        return []
    return session["messages"]

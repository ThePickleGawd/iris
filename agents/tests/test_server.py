from __future__ import annotations

import json

from fastapi.testclient import TestClient

import server


def test_health_and_device_registry_flow() -> None:
    server.device_registry.clear()
    client = TestClient(server.app)

    health = client.get("/health")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"

    register = client.post(
        "/devices",
        json={
            "id": "device-1",
            "name": "Test iPad",
            "host": "127.0.0.1",
            "port": 8935,
            "platform": "ipad",
        },
    )
    assert register.status_code == 200

    devices = client.get("/devices")
    assert devices.status_code == 200
    assert devices.json()["count"] == 1

    unregister = client.delete("/devices/device-1")
    assert unregister.status_code == 200
    assert unregister.json()["unregistered"] == "device-1"


def test_chat_endpoint_uses_selected_agent(monkeypatch) -> None:
    client = TestClient(server.app)

    async def fake_iris_run(chat_id: str, message: str):
        return {"response": f"iris:{chat_id}:{message}", "widgets": []}

    monkeypatch.setattr(server.iris_agent, "run", fake_iris_run)

    resp = client.post(
        "/chat",
        json={"agent": "iris", "chat_id": "chat-a", "message": "hello"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["chat_id"] == "chat-a"
    assert body["response"] == "iris:chat-a:hello"


def test_chat_stream_emits_final_and_widget_events(monkeypatch) -> None:
    client = TestClient(server.app)

    async def fake_codex_run(chat_id: str, message: str):
        return {
            "response": "final answer",
            "widgets": [{"html": "<div>Widget</div>"}],
        }

    monkeypatch.setattr(server.codex_agent, "run", fake_codex_run)

    resp = client.post(
        "/chat/stream",
        json={"agent": "codex", "chat_id": "chat-b", "message": "hi"},
    )

    assert resp.status_code == 200

    frames = []
    for line in resp.text.splitlines():
        if line.startswith("data: "):
            frames.append(json.loads(line[len("data: ") :]))

    kinds = [frame["kind"] for frame in frames]
    assert "status" in kinds
    assert "message.final" in kinds
    assert "widget.open" in kinds


def test_v1_agent_stream_routes_with_metadata_agent(monkeypatch) -> None:
    client = TestClient(server.app)

    async def fake_codex_run(chat_id: str, message: str):
        return {"response": f"codex:{chat_id}:{message}", "widgets": []}

    monkeypatch.setattr(server.codex_agent, "run", fake_codex_run)
    monkeypatch.setattr(server.sessions, "get_or_create", lambda *args, **kwargs: {"chat_id": "sess-1", "agent": "codex"})
    monkeypatch.setattr(server.sessions, "get_session", lambda *_: None)
    monkeypatch.setattr(server.sessions, "get_messages", lambda *_: [])

    resp = client.post(
        "/v1/agent/stream",
        json={
            "protocol_version": "1.0",
            "kind": "agent.request",
            "request_id": "req-1",
            "timestamp": "2026-02-14T00:00:00Z",
            "workspace_id": "sess-1",
            "session_id": "sess-1",
            "input": {"type": "text", "text": "hello"},
            "context": {"recent_messages": []},
            "metadata": {"agent": "codex"},
        },
    )

    assert resp.status_code == 200
    frames = []
    for line in resp.text.splitlines():
        if line.startswith("data: "):
            frames.append(json.loads(line[len("data: ") :]))

    assert any(frame.get("kind") == "status" for frame in frames)
    assert any(frame.get("kind") == "message.final" and frame.get("text") == "codex:sess-1:hello" for frame in frames)


def test_v1_agent_stream_uses_session_agent_when_not_provided(monkeypatch) -> None:
    client = TestClient(server.app)

    async def fake_codex_run(chat_id: str, message: str):
        return {"response": f"stored:{chat_id}:{message}", "widgets": []}

    monkeypatch.setattr(server.codex_agent, "run", fake_codex_run)
    monkeypatch.setattr(server.sessions, "get_or_create", lambda *args, **kwargs: {"chat_id": "sess-2", "agent": "codex"})
    monkeypatch.setattr(server.sessions, "get_session", lambda *_: {"id": "sess-2", "agent": "codex"})
    monkeypatch.setattr(server.sessions, "get_messages", lambda *_: [])

    resp = client.post(
        "/v1/agent/stream",
        json={
            "protocol_version": "1.0",
            "kind": "agent.request",
            "request_id": "req-2",
            "timestamp": "2026-02-14T00:00:00Z",
            "workspace_id": "sess-2",
            "session_id": "sess-2",
            "input": {"type": "text", "text": "ping"},
            "context": {"recent_messages": []},
        },
    )

    assert resp.status_code == 200
    frames = []
    for line in resp.text.splitlines():
        if line.startswith("data: "):
            frames.append(json.loads(line[len("data: ") :]))

    assert any(frame.get("kind") == "message.final" and frame.get("text") == "stored:sess-2:ping" for frame in frames)

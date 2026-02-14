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

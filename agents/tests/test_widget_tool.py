from __future__ import annotations

from types import SimpleNamespace

from tools import widget


def test_push_widget_queues_when_device_missing(monkeypatch) -> None:
    monkeypatch.setattr(widget, "_get_device_registry", lambda: {})

    context: dict = {"widgets": []}
    msg, payload = widget.handle_push_widget(
        {
            "html": "<div>Hello</div>",
            "target": "ipad",
            "widget_id": "hello-card",
        },
        context,
    )

    assert "queued for ipad" in msg
    assert payload is not None
    assert payload["widget_id"] == "hello-card"
    assert len(context["widgets"]) == 1


def test_push_widget_delivers_to_registered_device(monkeypatch) -> None:
    registry = {
        "ipad-1": {
            "platform": "iPadOS",
            "host": "127.0.0.1",
            "port": 8935,
            "name": "My iPad",
        }
    }
    monkeypatch.setattr(widget, "_get_device_registry", lambda: registry)

    def fake_post(*args, **kwargs):
        return SimpleNamespace(status_code=201, json=lambda: {"id": "obj-123"})

    monkeypatch.setattr(widget.httpx, "post", fake_post)

    context: dict = {"widgets": []}
    msg, payload = widget.handle_push_widget(
        {
            "html": "<div>Delivered</div>",
            "target": "ipad",
            "widget_id": "delivered-card",
            "width": 300,
            "height": 180,
        },
        context,
    )

    assert "delivered to ipad" in msg
    assert payload is not None
    assert payload["delivered"] is True
    assert payload["device_object_id"] == "obj-123"
    assert len(context["widgets"]) == 1

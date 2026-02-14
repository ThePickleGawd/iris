from __future__ import annotations

import httpx

PUSH_WIDGET_TOOL = {
    "type": "function",
    "function": {
        "name": "push_widget",
        "description": "Push an HTML widget to a target device. The widget will be rendered on the device's canvas.",
        "parameters": {
            "type": "object",
            "properties": {
                "html": {
                    "type": "string",
                    "description": "The HTML content of the widget to render.",
                },
                "target": {
                    "type": "string",
                    "enum": ["ipad", "mac"],
                    "description": "The target device to display the widget on.",
                },
                "widget_id": {
                    "type": "string",
                    "description": "A unique identifier for this widget. Use a descriptive slug.",
                },
                "width": {
                    "type": "number",
                    "description": "Widget width in points. Default 320.",
                },
                "height": {
                    "type": "number",
                    "description": "Widget height in points. Default 220.",
                },
            },
            "required": ["html", "target", "widget_id"],
        },
    },
}


def _get_device_registry() -> dict[str, dict]:
    """Import here to avoid circular imports at module load time."""
    try:
        from .. import server as server_module
        return server_module.device_registry
    except (ImportError, AttributeError):
        try:
            import server as server_module
            return server_module.device_registry
        except (ImportError, AttributeError):
            return {}


def handle_push_widget(
    arguments: dict, context: dict
) -> tuple[str, dict | None]:
    html = arguments["html"]
    target = arguments["target"]
    widget_id = arguments["widget_id"]
    width = arguments.get("width", 320)
    height = arguments.get("height", 220)

    # Mac widgets are delivered via the SSE stream (widget.open event),
    # not via HTTP POST — the Mac Electron app picks them up from the stream
    # and opens them as BrowserWindow popups.
    if target.lower() == "mac":
        widget = {
            "widget_id": widget_id,
            "target": target,
            "html": html,
            "width": width,
            "height": height,
            "delivered": True,
        }
        context.setdefault("widgets", []).append(widget)
        return f"Widget '{widget_id}' delivered to mac via stream.", widget

    # Find a device matching the target platform
    registry = _get_device_registry()
    device = None
    for dev in registry.values():
        if dev.get("platform", "").lower() in _platform_aliases(target):
            device = dev
            break

    if not device:
        # Still record in context for the response, but warn about delivery
        widget = {"widget_id": widget_id, "target": target, "html": html}
        context.setdefault("widgets", []).append(widget)
        return f"Widget '{widget_id}' queued for {target} but no {target} device is currently registered.", widget

    host = device["host"]
    port = device["port"]

    # POST to iPad's canvas API
    try:
        resp = httpx.post(
            f"http://{host}:{port}/api/v1/objects",
            json={
                "html": html,
                "width": width,
                "height": height,
            },
            timeout=10,
        )
        if resp.status_code in (200, 201):
            result = resp.json()
            widget = {
                "widget_id": widget_id,
                "target": target,
                "html": html,
                "device_object_id": result.get("id"),
                "delivered": True,
            }
            context.setdefault("widgets", []).append(widget)
            return f"Widget '{widget_id}' delivered to {target} ({device.get('name', host)}).", widget
        else:
            widget = {"widget_id": widget_id, "target": target, "html": html, "delivered": False}
            context.setdefault("widgets", []).append(widget)
            return f"Widget '{widget_id}' delivery failed: {target} returned {resp.status_code}.", widget
    except httpx.HTTPError as exc:
        widget = {"widget_id": widget_id, "target": target, "html": html, "delivered": False}
        context.setdefault("widgets", []).append(widget)
        return f"Widget '{widget_id}' delivery failed: {exc}", widget


def _platform_aliases(target: str) -> set[str]:
    """Map target name to possible platform strings from device info."""
    target = target.lower()
    if target == "ipad":
        return {"ipados", "ipad", "ios"}
    if target == "mac":
        return {"macos", "mac"}
    return {target}

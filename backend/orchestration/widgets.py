from __future__ import annotations

import math
import uuid
from typing import Any

VALID_COORD_SPACES = {
    "viewport_offset",
    "viewport_center_offset",
    "viewport_local",
    "viewport_top_left",
    "canvas_absolute",
    "document_axis",
}
VALID_ANCHORS = {"top_left", "center"}


def _safe_float(v: Any, default: float) -> float:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    return f if math.isfinite(f) else default


def _safe_int(v: Any, default: int, *, lo: int, hi: int) -> int:
    try:
        i = int(float(v))
    except (TypeError, ValueError):
        i = default
    if i < lo:
        return lo
    if i > hi:
        return hi
    return i


def _normalize_coord_space(raw: Any) -> str:
    s = str(raw or "viewport_offset").strip().lower()
    if s in {"viewport_offset", "viewport_center_offset", "viewport_center"}:
        return "viewport_center_offset"
    if s in {"viewport_local", "viewport_top_left", "viewport_topleft"}:
        return "viewport_local"
    if s in {"canvas_absolute", "document_axis"}:
        return s
    return "viewport_center_offset"


def _resolve_target(widget: dict[str, Any], fallback_target: str) -> str:
    target = widget.get("target") or widget.get("target_device") or fallback_target
    t = str(target or fallback_target).strip().lower()
    return t if t in {"ipad", "mac"} else fallback_target


def normalize_widget_specs(raw_widgets: list[Any], *, fallback_target: str) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for raw in raw_widgets:
        if not isinstance(raw, dict):
            continue
        html = str(raw.get("html") or "").strip()
        if not html:
            continue

        coord_space = _normalize_coord_space(raw.get("coordinate_space"))

        anchor = str(raw.get("anchor") or "top_left").strip().lower()
        if anchor not in VALID_ANCHORS:
            anchor = "top_left"

        entry: dict[str, Any] = {
            "id": str(raw.get("widget_id") or raw.get("id") or str(uuid.uuid4())),
            "type": str(raw.get("type") or "html").strip().lower(),
            "html": html,
            "target": _resolve_target(raw, fallback_target),
            "width": _safe_int(raw.get("width"), 320, lo=120, hi=1800),
            "height": _safe_int(raw.get("height"), 220, lo=100, hi=1600),
            "x": _safe_float(raw.get("x"), 0.0),
            "y": _safe_float(raw.get("y"), 0.0),
            "coordinate_space": coord_space,
            "anchor": anchor,
        }
        if raw.get("svg"):
            entry["svg"] = raw["svg"]
        normalized.append(entry)
    return normalized


def build_widget_events(normalized_widgets: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    for w in normalized_widgets:
        record = {
            "id": w["id"],
            "type": w.get("type", "html"),
            "html": w["html"],
            "target": w["target"],
            "width": w["width"],
            "height": w["height"],
            "x": w["x"],
            "y": w["y"],
            "coordinate_space": w["coordinate_space"],
            "anchor": w["anchor"],
        }
        if w.get("svg"):
            record["svg"] = w["svg"]
        records.append(record)

        # Diagram widgets targeting iPad use the draw endpoint, not widget.open
        is_ipad_diagram = w.get("type") == "diagram" and w.get("target") == "ipad" and w.get("svg")
        if is_ipad_diagram:
            events.append({
                "kind": "draw",
                "draw": {
                    "id": record["id"],
                    "target": record["target"],
                    "svg": record["svg"],
                    "x": record["x"],
                    "y": record["y"],
                    "coordinate_space": record["coordinate_space"],
                },
            })
        else:
            events.append({
                "kind": "widget.open",
                "widget": {
                    "kind": "html",
                    "id": record["id"],
                    "target": record["target"],
                    "payload": {"html": record["html"]},
                    "width": record["width"],
                    "height": record["height"],
                    "x": record["x"],
                    "y": record["y"],
                    "coordinate_space": record["coordinate_space"],
                    "anchor": record["anchor"],
                },
            })
    return records, events

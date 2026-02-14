from __future__ import annotations

from typing import Any


def _safe_float(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def map_norm_to_document_axis(
    nx: float,
    ny: float,
    coordinate_snapshot: dict[str, Any] | None,
) -> tuple[float | None, float | None]:
    if not isinstance(coordinate_snapshot, dict):
        return None, None

    top_left = coordinate_snapshot.get("viewportTopLeftAxis") or {}
    bottom_right = coordinate_snapshot.get("viewportBottomRightAxis") or {}

    tlx = _safe_float(top_left.get("x"))
    tly = _safe_float(top_left.get("y"))
    brx = _safe_float(bottom_right.get("x"))
    bry = _safe_float(bottom_right.get("y"))
    if tlx is None or tly is None or brx is None or bry is None:
        return None, None

    nx = min(max(nx, 0.0), 1.0)
    ny = min(max(ny, 0.0), 1.0)
    x = tlx + (brx - tlx) * nx
    y = tly + (bry - tly) * ny
    return x, y


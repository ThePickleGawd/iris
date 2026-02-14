from __future__ import annotations

import math
from typing import Any


def _safe_float(v: Any) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(f):
        return None
    return f


def sanitize_coordinate_snapshot(snapshot: Any) -> dict[str, Any] | None:
    if not isinstance(snapshot, dict):
        return None
    required_paths = [
        ("viewportTopLeftAxis", "x"),
        ("viewportTopLeftAxis", "y"),
        ("viewportBottomRightAxis", "x"),
        ("viewportBottomRightAxis", "y"),
    ]
    out = dict(snapshot)
    for parent, key in required_paths:
        parent_obj = out.get(parent)
        if not isinstance(parent_obj, dict):
            return None
        val = _safe_float(parent_obj.get(key))
        if val is None:
            return None
        parent_obj[key] = val

    tl = out["viewportTopLeftAxis"]
    br = out["viewportBottomRightAxis"]
    if tl["x"] >= br["x"] or tl["y"] >= br["y"]:
        return None
    return out


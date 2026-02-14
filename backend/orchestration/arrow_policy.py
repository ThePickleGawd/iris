from __future__ import annotations

import re
from typing import Any

from grounding import detect_latest_arrows


_ARROW_PLACEMENT_PATTERNS = [
    r"\barrow\b",
    r"\barrow tip\b",
    r"\bend of the arrow\b",
    r"\bpointing to\b",
    r"\bdirection\b",
]


def requests_arrow_placement(text: str) -> bool:
    lowered = (text or "").strip().lower()
    if not lowered:
        return False
    return any(re.search(p, lowered) for p in _ARROW_PLACEMENT_PATTERNS)


def apply_arrow_tip_policy(
    widgets: list[dict[str, Any]],
    *,
    message: str,
    device: str | None,
    session_id: str | None,
) -> dict[str, Any]:
    if not widgets:
        return {"applied": False, "reason": "no_widgets"}
    if not requests_arrow_placement(message):
        return {"applied": False, "reason": "no_arrow_intent"}

    arrows = detect_latest_arrows(device=device, session_id=session_id)
    candidates = [
        a for a in arrows.arrows
        if a.tip_document_axis_x is not None and a.tip_document_axis_y is not None
    ]
    if not arrows.ok or not candidates:
        return {"applied": False, "reason": "no_arrow_tip_coordinates", "arrow_ok": arrows.ok}

    best = max(candidates, key=lambda a: float(a.confidence))
    tx = float(best.tip_document_axis_x)  # type: ignore[arg-type]
    ty = float(best.tip_document_axis_y)  # type: ignore[arg-type]

    for w in widgets:
        # Force deterministic placement to arrow tip for these requests.
        w["x"] = tx
        w["y"] = ty
        w["coordinate_space"] = "document_axis"
        w["anchor"] = "center"

    return {
        "applied": True,
        "reason": "snapped_to_arrow_tip",
        "arrow_confidence": best.confidence,
        "tip_document_axis": {"x": tx, "y": ty},
    }


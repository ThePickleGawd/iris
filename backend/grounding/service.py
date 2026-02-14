from __future__ import annotations

import json
import os
from typing import Any

from .coordinates import map_norm_to_document_axis
from .providers import detect_arrows_with_claude, detect_noop
from .store import latest_screenshot_row, load_screenshot_bytes
from .types import ArrowDetectionResult


def _parse_coordinate_snapshot(row: dict[str, Any]) -> dict[str, Any] | None:
    raw = row.get("coordinate_snapshot")
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None
    return None


def detect_latest_arrows(device: str | None = None, session_id: str | None = None) -> ArrowDetectionResult:
    row = latest_screenshot_row(device=device, session_id=session_id)
    if not row:
        return ArrowDetectionResult(
            ok=False,
            source="grounding",
            reason="no screenshot found",
            device_id=device,
            session_id=session_id,
        )

    image_bytes = load_screenshot_bytes(row)
    if not image_bytes:
        return ArrowDetectionResult(
            ok=False,
            source="grounding",
            screenshot_id=str(row.get("id") or ""),
            device_id=str(row.get("device_id") or ""),
            session_id=str(row.get("session_id") or ""),
            reason="screenshot file missing",
        )

    provider = (os.environ.get("IRIS_GROUNDING_PROVIDER", "claude").strip() or "claude").lower()
    if provider == "none":
        result = detect_noop()
    else:
        result = detect_arrows_with_claude(
            image_bytes,
            str(row.get("mime_type") or "image/png"),
            screenshot_id=str(row.get("id") or ""),
            device_id=str(row.get("device_id") or ""),
            session_id=str(row.get("session_id") or ""),
        )

    snapshot = _parse_coordinate_snapshot(row)
    for arrow in result.arrows:
        tip_x, tip_y = map_norm_to_document_axis(arrow.tip_norm_x, arrow.tip_norm_y, snapshot)
        tail_x, tail_y = map_norm_to_document_axis(arrow.tail_norm_x, arrow.tail_norm_y, snapshot)
        arrow.tip_document_axis_x = tip_x
        arrow.tip_document_axis_y = tip_y
        arrow.tail_document_axis_x = tail_x
        arrow.tail_document_axis_y = tail_y

    if not result.screenshot_id:
        result.screenshot_id = str(row.get("id") or "")
    if not result.device_id:
        result.device_id = str(row.get("device_id") or "")
    if not result.session_id:
        result.session_id = str(row.get("session_id") or "")
    return result


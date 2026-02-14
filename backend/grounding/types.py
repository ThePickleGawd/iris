from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class ArrowDetection:
    tip_norm_x: float
    tip_norm_y: float
    tail_norm_x: float
    tail_norm_y: float
    confidence: float
    direction: str = ""
    tip_document_axis_x: float | None = None
    tip_document_axis_y: float | None = None
    tail_document_axis_x: float | None = None
    tail_document_axis_y: float | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "tip_norm": {"x": self.tip_norm_x, "y": self.tip_norm_y},
            "tail_norm": {"x": self.tail_norm_x, "y": self.tail_norm_y},
            "confidence": self.confidence,
            "direction": self.direction,
            "tip_document_axis": (
                {"x": self.tip_document_axis_x, "y": self.tip_document_axis_y}
                if self.tip_document_axis_x is not None and self.tip_document_axis_y is not None
                else None
            ),
            "tail_document_axis": (
                {"x": self.tail_document_axis_x, "y": self.tail_document_axis_y}
                if self.tail_document_axis_x is not None and self.tail_document_axis_y is not None
                else None
            ),
        }


@dataclass
class ArrowDetectionResult:
    ok: bool
    source: str
    screenshot_id: str | None = None
    device_id: str | None = None
    session_id: str | None = None
    arrows: list[ArrowDetection] = field(default_factory=list)
    reason: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "source": self.source,
            "screenshot_id": self.screenshot_id,
            "device_id": self.device_id,
            "session_id": self.session_id,
            "count": len(self.arrows),
            "arrows": [a.to_json() for a in self.arrows],
            "reason": self.reason,
        }


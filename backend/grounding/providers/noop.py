from __future__ import annotations

from ..types import ArrowDetectionResult


def detect_noop(*_: object, **__: object) -> ArrowDetectionResult:
    return ArrowDetectionResult(
        ok=False,
        source="noop",
        reason="grounding provider disabled",
    )


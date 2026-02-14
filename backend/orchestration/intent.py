from __future__ import annotations

import re

_WIDGET_INTENT_PATTERNS = [
    r"\bcreate\b.{0,30}\bwidget\b",
    r"\bmake\b.{0,30}\bwidget\b",
    r"\badd\b.{0,30}\bwidget\b",
    r"\bgenerate\b.{0,30}\bwidget\b",
    r"\bbuild\b.{0,30}\bwidget\b",
    r"\bshow\b.{0,30}\bwidget\b",
]


def requests_widget(text: str) -> bool:
    lowered = (text or "").strip().lower()
    if not lowered:
        return False
    return any(re.search(p, lowered) for p in _WIDGET_INTENT_PATTERNS)


from __future__ import annotations

import json
from pathlib import Path
from typing import Any


BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
SCREENSHOTS_META_DIR = DATA_DIR / "screenshot_meta"


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_screenshot_rows() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not SCREENSHOTS_META_DIR.exists():
        return rows
    for p in SCREENSHOTS_META_DIR.glob("*.json"):
        row = _load_json(p)
        if row:
            rows.append(row)
    rows.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
    return rows


def latest_screenshot_row(device: str | None = None, session_id: str | None = None) -> dict[str, Any] | None:
    rows = list_screenshot_rows()
    for row in rows:
        if device and str(row.get("device_id") or "").strip() != device:
            continue
        if session_id and str(row.get("session_id") or "").strip() != session_id:
            continue
        return row
    return None


def load_screenshot_bytes(row: dict[str, Any]) -> bytes | None:
    file_path = Path(str(row.get("file_path") or ""))
    if not file_path.exists() or not file_path.is_file():
        return None
    try:
        return file_path.read_bytes()
    except OSError:
        return None


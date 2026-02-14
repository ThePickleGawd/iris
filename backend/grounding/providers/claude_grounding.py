from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from typing import Any

from ..types import ArrowDetection, ArrowDetectionResult


DEFAULT_MODEL = "claude-sonnet-4-5-20250929"


def _extract_json_block(text: str) -> dict[str, Any] | None:
    s = text.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        s = s.rsplit("```", 1)[0]
    try:
        data = json.loads(s)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def detect_arrows_with_claude(
    image_bytes: bytes,
    mime_type: str,
    *,
    screenshot_id: str | None,
    device_id: str | None,
    session_id: str | None,
) -> ArrowDetectionResult:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        return ArrowDetectionResult(
            ok=False,
            source="claude-grounding",
            screenshot_id=screenshot_id,
            device_id=device_id,
            session_id=session_id,
            reason="ANTHROPIC_API_KEY not set",
        )

    model = os.environ.get("IRIS_GROUNDING_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL

    b64 = base64.b64encode(image_bytes).decode("ascii")
    prompt = (
        "Detect drawn arrows in this image.\n"
        "Return strict JSON only with shape:\n"
        "{\n"
        '  "arrows": [\n'
        "    {\n"
        '      "tip_norm": {"x": 0.0, "y": 0.0},\n'
        '      "tail_norm": {"x": 0.0, "y": 0.0},\n'
        '      "confidence": 0.0,\n'
        '      "direction": "right|left|up|down|diagonal"\n'
        "    }\n"
        "  ]\n"
        "}\n"
        "Rules: normalized coordinates in [0,1], confidence in [0,1], only true arrows."
    )
    body = {
        "model": model,
        "max_tokens": 1000,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image", "source": {"type": "base64", "media_type": mime_type, "data": b64}},
                ],
            }
        ],
    }

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")
        return ArrowDetectionResult(
            ok=False,
            source="claude-grounding",
            screenshot_id=screenshot_id,
            device_id=device_id,
            session_id=session_id,
            reason=f"Anthropic HTTP {exc.code}: {detail[:180]}",
        )
    except Exception as exc:
        return ArrowDetectionResult(
            ok=False,
            source="claude-grounding",
            screenshot_id=screenshot_id,
            device_id=device_id,
            session_id=session_id,
            reason=str(exc),
        )

    blocks = data.get("content", [])
    text = "".join(
        b.get("text", "")
        for b in blocks
        if isinstance(b, dict) and b.get("type") == "text"
    )
    parsed = _extract_json_block(text)
    if not parsed:
        return ArrowDetectionResult(
            ok=False,
            source="claude-grounding",
            screenshot_id=screenshot_id,
            device_id=device_id,
            session_id=session_id,
            reason="invalid JSON returned by grounding model",
        )

    arrows_raw = parsed.get("arrows", [])
    arrows: list[ArrowDetection] = []
    if isinstance(arrows_raw, list):
        for item in arrows_raw:
            if not isinstance(item, dict):
                continue
            tip = item.get("tip_norm") if isinstance(item.get("tip_norm"), dict) else {}
            tail = item.get("tail_norm") if isinstance(item.get("tail_norm"), dict) else {}
            try:
                tip_x = float(tip.get("x"))
                tip_y = float(tip.get("y"))
                tail_x = float(tail.get("x"))
                tail_y = float(tail.get("y"))
                conf = float(item.get("confidence", 0))
            except (TypeError, ValueError):
                continue
            arrows.append(
                ArrowDetection(
                    tip_norm_x=min(max(tip_x, 0.0), 1.0),
                    tip_norm_y=min(max(tip_y, 0.0), 1.0),
                    tail_norm_x=min(max(tail_x, 0.0), 1.0),
                    tail_norm_y=min(max(tail_y, 0.0), 1.0),
                    confidence=min(max(conf, 0.0), 1.0),
                    direction=str(item.get("direction") or ""),
                )
            )

    return ArrowDetectionResult(
        ok=True,
        source="claude-grounding",
        screenshot_id=screenshot_id,
        device_id=device_id,
        session_id=session_id,
        arrows=arrows,
    )


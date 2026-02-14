"""
Trajectory logger for iris agent runs.
Captures structured JSONL logs to agents/log/ for the trajectory visualizer.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

LOG_DIR = Path(__file__).parent / "log"


class TrajectoryLogger:
    def __init__(
        self,
        session_id: str,
        agent: str = "iris",
        model: str = "unknown",
        devices: list[str] | None = None,
    ):
        self.session_id = session_id
        self.agent = agent
        self.model = model
        self.devices = devices or ["mac", "ipad"]
        self.lines: list[dict] = []
        self.step = 0
        self.started_at = datetime.now(timezone.utc).isoformat()

        # Current agent turn state
        self._turn_start: float | None = None
        self._turn_thought = ""
        self._turn_tool_calls: list[dict] = []

    def log_metadata(self, task: str) -> None:
        self.lines.append({
            "type": "metadata",
            "session_id": self.session_id,
            "agent": self.agent,
            "model": self.model,
            "started_at": self.started_at,
            "task": task[:300],
            "devices": self.devices,
        })

    def log_user_message(self, content: str) -> None:
        self.lines.append({
            "type": "user_message",
            "step": self.step,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "content": content,
        })
        self.step += 1

    def start_agent_turn(self) -> None:
        self._turn_start = time.monotonic()
        self._turn_thought = ""
        self._turn_tool_calls = []

    def append_thought(self, delta: str) -> None:
        self._turn_thought += delta

    def log_tool_call(
        self,
        tool_id: str,
        name: str,
        input_data: dict,
        result: Any = None,
        screenshot_base64: str | None = None,
        widget_html: str | None = None,
        duration_ms: int = 0,
    ) -> None:
        tc: dict[str, Any] = {
            "id": tool_id,
            "name": name,
            "input": _safe_serialize(input_data),
            "result": _safe_result(name, result),
            "duration_ms": duration_ms,
        }
        if screenshot_base64:
            tc["screenshot_base64"] = screenshot_base64
        if widget_html:
            tc["widget_html"] = widget_html
        if name == "push_widget":
            tc["widget_spec"] = {
                "title": input_data.get("widget_id", "Widget"),
                "kind": "html",
                "width": input_data.get("width", 320),
                "height": input_data.get("height", 220),
                "html": input_data.get("html", ""),
                "target_device": input_data.get("target", ""),
            }
        self._turn_tool_calls.append(tc)

    def end_agent_turn(self) -> None:
        elapsed = 0
        if self._turn_start is not None:
            elapsed = int((time.monotonic() - self._turn_start) * 1000)

        self.lines.append({
            "type": "agent_turn",
            "step": self.step,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "thought": self._turn_thought,
            "tool_calls": self._turn_tool_calls,
            "duration_ms": elapsed,
        })
        self.step += 1
        self._turn_start = None
        self._turn_thought = ""
        self._turn_tool_calls = []

    def log_final_response(self, content: str) -> None:
        total_ms = sum(
            line.get("duration_ms", 0)
            for line in self.lines
            if line.get("type") == "agent_turn"
        )
        if self.lines and self.lines[0].get("type") == "metadata":
            self.lines[0]["ended_at"] = datetime.now(timezone.utc).isoformat()

        self.lines.append({
            "type": "final_response",
            "step": self.step,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "content": content,
            "total_duration_ms": total_ms,
        })
        self.step += 1

    def save(self) -> str:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{self.session_id}_{ts}.jsonl"
        path = LOG_DIR / filename

        with open(path, "w") as f:
            for line in self.lines:
                f.write(json.dumps(line) + "\n")

        return str(path)


def _safe_serialize(obj: Any) -> Any:
    if obj is None:
        return None
    if isinstance(obj, (str, int, float, bool)):
        return obj
    if isinstance(obj, dict):
        return {k: _safe_serialize(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_safe_serialize(v) for v in obj]
    return str(obj)


def _safe_result(tool_name: str, result: Any) -> Any:
    """Serialize tool results, truncating large data like images."""
    if result is None:
        return None
    if isinstance(result, list):
        # Multimodal content blocks (from screenshot tool)
        cleaned = []
        for block in result:
            if isinstance(block, dict) and block.get("type") == "image":
                cleaned.append({"type": "image", "note": "base64 image captured"})
            else:
                cleaned.append(_safe_serialize(block))
        return cleaned
    if isinstance(result, str) and len(result) > 2000:
        return result[:2000] + "... (truncated)"
    return _safe_serialize(result)

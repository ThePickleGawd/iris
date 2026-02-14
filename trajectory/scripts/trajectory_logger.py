"""
Trajectory logger for the iris agent.

Hooks into the iris agent's tool-use loop to capture structured trajectory
data as JSONL for the trajectory visualizer.

Usage — wrap run_stream():

    from trajectory.scripts.trajectory_logger import TrajectoryLogger

    logger = TrajectoryLogger(
        session_id=chat_id,
        agent="iris",
        model="claude-sonnet-4-5-20250929",
        output_dir="trajectory/public/demo",
    )
    logger.log_metadata(task=user_message)
    logger.log_user_message(user_message)

    # In the tool-use loop:
    logger.start_agent_turn(thought=text_so_far)
    logger.log_tool_call(
        tool_id=block.id,
        name=block.name,
        input_data=block.input,
        result=result_content,
        screenshot_base64=...,  # if read_screenshot
        widget_html=...,         # if push_widget
    )
    logger.end_agent_turn()

    # At the end:
    logger.log_final_response(text)
    logger.save()
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class TrajectoryLogger:
    def __init__(
        self,
        session_id: str,
        agent: str = "iris",
        model: str = "claude-sonnet-4-5-20250929",
        output_dir: str | None = None,
        devices: list[str] | None = None,
    ):
        self.session_id = session_id
        self.agent = agent
        self.model = model
        self.output_dir = output_dir or "."
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
            "task": task[:200],
            "devices": self.devices,
        })

    def log_user_message(
        self,
        content: str,
        screenshots: list[dict] | None = None,
        transcripts: list[str] | None = None,
    ) -> None:
        entry: dict[str, Any] = {
            "type": "user_message",
            "step": self.step,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "content": content,
        }
        if screenshots:
            entry["screenshots"] = screenshots
        if transcripts:
            entry["transcripts"] = transcripts
        self.lines.append(entry)
        self.step += 1

    def start_agent_turn(self, thought: str = "") -> None:
        self._turn_start = time.monotonic()
        self._turn_thought = thought
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
        widget_spec: dict | None = None,
        duration_ms: int | None = None,
    ) -> None:
        tc: dict[str, Any] = {
            "id": tool_id,
            "name": name,
            "input": input_data,
            "result": _safe_serialize(result),
        }
        if screenshot_base64:
            tc["screenshot_base64"] = screenshot_base64
        if widget_html:
            tc["widget_html"] = widget_html
        if widget_spec:
            tc["widget_spec"] = widget_spec
        if duration_ms is not None:
            tc["duration_ms"] = duration_ms
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
        total = 0
        for line in self.lines:
            if line.get("type") == "agent_turn":
                total += line.get("duration_ms", 0)

        # Update metadata with ended_at
        if self.lines and self.lines[0].get("type") == "metadata":
            self.lines[0]["ended_at"] = datetime.now(timezone.utc).isoformat()

        self.lines.append({
            "type": "final_response",
            "step": self.step,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "content": content,
            "total_duration_ms": total,
        })
        self.step += 1

    def save(self, filename: str | None = None) -> str:
        if filename is None:
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"trajectory_{self.session_id}_{ts}.jsonl"

        path = Path(self.output_dir) / filename
        path.parent.mkdir(parents=True, exist_ok=True)

        with open(path, "w") as f:
            for line in self.lines:
                f.write(json.dumps(line) + "\n")

        return str(path)

    def to_jsonl(self) -> str:
        return "\n".join(json.dumps(line) for line in self.lines) + "\n"


def _safe_serialize(obj: Any) -> Any:
    """Make an object JSON-safe, stripping binary data."""
    if obj is None:
        return None
    if isinstance(obj, (str, int, float, bool)):
        return obj
    if isinstance(obj, dict):
        return {k: _safe_serialize(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_safe_serialize(v) for v in obj]
    return str(obj)

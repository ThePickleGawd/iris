#!/usr/bin/env python3
"""
Export iris agent sessions from the backend as trajectory JSONL files.

Usage:
    python export_trajectory.py --session-id <id>
    python export_trajectory.py --session-id <id> --output my_trajectory.jsonl
    python export_trajectory.py --session-id <id> --backend http://localhost:5001

This reads stored messages from the iris backend and reconstructs a trajectory
file. Note: since tool call details aren't persisted in messages, each
assistant message becomes a simplified agent_turn without structured tool data.

For full trajectory capture with screenshots and widget HTML, use the
TrajectoryLogger (trajectory_logger.py) integrated into the agent loop.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

import requests


def export_session(
    backend_url: str, session_id: str, output_path: str, include_screenshots: bool = False
) -> None:
    # Fetch session metadata
    resp = requests.get(f"{backend_url}/api/sessions/{session_id}", timeout=5)
    if resp.status_code == 404:
        print(f"Session {session_id} not found", file=sys.stderr)
        sys.exit(1)
    session = resp.json()

    # Fetch messages
    resp = requests.get(
        f"{backend_url}/api/messages",
        params={"session_id": session_id, "limit": 500},
        timeout=10,
    )
    messages = resp.json().get("items", [])

    if not messages:
        print(f"No messages found for session {session_id}", file=sys.stderr)
        sys.exit(1)

    # Optionally fetch screenshots
    screenshots_by_ts: dict[str, dict] = {}
    if include_screenshots:
        resp = requests.get(
            f"{backend_url}/api/screenshots",
            params={"session_id": session_id, "limit": 100},
            timeout=10,
        )
        for ss in resp.json().get("items", []):
            # Fetch actual image data
            img_resp = requests.get(
                f"{backend_url}/api/screenshots/{ss['id']}/file", timeout=10
            )
            if img_resp.status_code == 200:
                import base64
                ss["base64"] = base64.b64encode(img_resp.content).decode()
                screenshots_by_ts[ss["captured_at"]] = ss

    # Extract task from first user message
    task = "Unknown task"
    for msg in messages:
        if msg["role"] == "user":
            task = msg["content"][:200]
            break

    lines: list[dict] = []

    # Metadata
    lines.append({
        "type": "metadata",
        "session_id": session_id,
        "agent": session.get("agent", "iris"),
        "model": session.get("metadata", {}).get("model", "unknown"),
        "started_at": session.get("created_at", datetime.now(timezone.utc).isoformat()),
        "ended_at": session.get("updated_at"),
        "task": task,
    })

    # Convert messages to trajectory steps
    step = 0
    for msg in messages:
        ts = msg.get("created_at", datetime.now(timezone.utc).isoformat())

        if msg["role"] == "user":
            entry: dict = {
                "type": "user_message",
                "step": step,
                "timestamp": ts,
                "content": msg["content"],
            }
            lines.append(entry)
        else:
            # Assistant messages become agent_turns (simplified, no tool call data)
            entry = {
                "type": "agent_turn",
                "step": step,
                "timestamp": ts,
                "thought": msg["content"],
                "tool_calls": [],
                "duration_ms": 0,
            }
            lines.append(entry)

        step += 1

    # If the last step was an assistant message, convert it to final_response
    if lines and lines[-1].get("type") == "agent_turn":
        last = lines.pop()
        lines.append({
            "type": "final_response",
            "step": last["step"],
            "timestamp": last["timestamp"],
            "content": last["thought"],
            "total_duration_ms": 0,
        })

    # Write output
    with open(output_path, "w") as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")

    print(f"Exported {len(lines)} lines ({step} steps) to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export iris session as trajectory JSONL")
    parser.add_argument("--session-id", required=True, help="Session ID to export")
    parser.add_argument("--output", "-o", default=None, help="Output file path")
    parser.add_argument(
        "--backend",
        default="http://localhost:5001",
        help="Backend URL (default: http://localhost:5001)",
    )
    parser.add_argument(
        "--screenshots", action="store_true", help="Include screenshot image data"
    )
    args = parser.parse_args()

    output = args.output or f"trajectory_{args.session_id}.jsonl"
    export_session(args.backend, args.session_id, output, args.screenshots)


if __name__ == "__main__":
    main()

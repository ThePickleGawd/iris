from __future__ import annotations

import asyncio
import json

import sessions

# Track codex session IDs per chat for continuity
_codex_sessions: dict[str, str] = {}


async def run(chat_id: str, message: str) -> dict:
    sessions.add_message(chat_id, "user", message)

    cmd = ["codex", "--prompt", message, "--full-auto"]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(), timeout=120
        )
        stdout = stdout_bytes.decode()
        stderr = stderr_bytes.decode()
        returncode = proc.returncode
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        assistant_text = "Error: codex command timed out after 120 seconds"
        sessions.add_message(chat_id, "assistant", assistant_text)
        return {"response": assistant_text, "widgets": []}

    # Parse JSON output if available
    assistant_text = ""
    for line in stdout.strip().splitlines():
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        if event.get("type") == "system" and "session_id" in event:
            _codex_sessions[chat_id] = event["session_id"]

        if event.get("type") == "result":
            assistant_text = event.get("result", assistant_text)

    if not assistant_text and stdout.strip():
        assistant_text = stdout.strip()

    if returncode != 0 and not assistant_text:
        assistant_text = f"Error: {stderr.strip() or 'codex command failed'}"

    sessions.add_message(chat_id, "assistant", assistant_text)

    return {
        "response": assistant_text,
        "widgets": [],
    }

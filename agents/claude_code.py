from __future__ import annotations

import asyncio
import json

try:
    from . import sessions, session_store
except ImportError:
    import sessions
    import session_store


async def run(chat_id: str, message: str) -> dict:
    sessions.add_message(chat_id, "user", message)

    cmd = ["claude", "-p", message, "--output-format", "stream-json"]

    # Resume existing session if we have one
    stored = session_store.load(chat_id)
    if stored and stored.get("cli_session_id"):
        cmd.extend(["--resume", stored["cli_session_id"]])

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
        assistant_text = "Error: claude command timed out after 120 seconds"
        sessions.add_message(chat_id, "assistant", assistant_text)
        return {"response": assistant_text, "widgets": []}

    # Parse streamed JSON lines to extract the final text and session ID
    assistant_text = ""
    for line in stdout.strip().splitlines():
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Capture session ID from init message
        if event.get("type") == "system" and "session_id" in event:
            session_store.save(chat_id, "claude_code", event["session_id"])

        # Accumulate assistant text from result messages
        if event.get("type") == "result":
            assistant_text = event.get("result", assistant_text)

    if not assistant_text and stdout.strip():
        # Fallback: use raw output if we couldn't parse structured data
        assistant_text = stdout.strip()

    if returncode != 0 and not assistant_text:
        assistant_text = f"Error: {stderr.strip() or 'claude command failed'}"

    sessions.add_message(chat_id, "assistant", assistant_text)

    return {
        "response": assistant_text,
        "widgets": [],
    }

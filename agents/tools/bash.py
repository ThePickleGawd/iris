from __future__ import annotations

import os
import subprocess

RUN_BASH_TOOL = {
    "type": "function",
    "function": {
        "name": "run_bash",
        "description": "Run a shell command on the host using bash and return stdout/stderr.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Shell command to execute.",
                },
                "cwd": {
                    "type": "string",
                    "description": "Optional working directory for the command.",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "description": "Execution timeout in seconds. Default 20.",
                },
                "max_output_chars": {
                    "type": "integer",
                    "description": "Maximum characters to return across stdout/stderr. Default 12000.",
                },
            },
            "required": ["command"],
        },
    },
}


def _trim(text: str, max_chars: int) -> tuple[str, bool]:
    if len(text) <= max_chars:
        return text, False
    return text[:max_chars], True


def handle_run_bash(arguments: dict, context: dict) -> tuple[str, None]:
    command = arguments["command"]
    cwd = arguments.get("cwd")
    timeout_seconds = int(arguments.get("timeout_seconds", 20))
    max_output_chars = int(arguments.get("max_output_chars", 12000))

    if timeout_seconds < 1:
        timeout_seconds = 1
    if timeout_seconds > 300:
        timeout_seconds = 300
    if max_output_chars < 500:
        max_output_chars = 500
    if max_output_chars > 50000:
        max_output_chars = 50000

    if cwd:
        cwd = os.path.abspath(cwd)
        if not os.path.isdir(cwd):
            return f"run_bash error: cwd does not exist: {cwd}", None

    try:
        proc = subprocess.run(
            ["bash", "-lc", command],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        return f"run_bash timeout after {timeout_seconds}s for command: {command}", None
    except Exception as exc:
        return f"run_bash failed: {exc}", None

    stdout, stdout_truncated = _trim(proc.stdout or "", max_output_chars)
    remaining = max(max_output_chars - len(stdout), 0)
    stderr, stderr_truncated = _trim(proc.stderr or "", remaining)

    lines = [
        f"exit_code: {proc.returncode}",
        f"cwd: {cwd or os.getcwd()}",
    ]
    if stdout:
        lines.append("stdout:")
        lines.append(stdout.rstrip("\n"))
    if stderr:
        lines.append("stderr:")
        lines.append(stderr.rstrip("\n"))
    if stdout_truncated or stderr_truncated:
        lines.append(
            f"(output truncated to {max_output_chars} chars; stdout_truncated={stdout_truncated}, stderr_truncated={stderr_truncated})"
        )

    return "\n".join(lines), None

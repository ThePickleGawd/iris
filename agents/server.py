from __future__ import annotations

import json
from typing import AsyncGenerator

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

try:
    from . import sessions, iris_agent, claude_code, codex_agent
except ImportError:
    import sessions
    import iris_agent
    import claude_code
    import codex_agent

app = FastAPI(title="Iris Agent Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Device Registry (in-memory) ──────────────────────────────────────────────
# Maps device_id -> {id, name, host, port, platform, ...}
device_registry: dict[str, dict] = {}


class DeviceRegistration(BaseModel):
    id: str
    name: str
    host: str
    port: int
    platform: str
    model: str | None = None
    system: str | None = None


@app.post("/devices")
async def register_device(device: DeviceRegistration):
    device_registry[device.id] = device.model_dump()
    return {"registered": True, "device_id": device.id}


@app.get("/devices")
async def list_devices():
    return {"devices": list(device_registry.values()), "count": len(device_registry)}


@app.delete("/devices/{device_id}")
async def unregister_device(device_id: str):
    if device_id in device_registry:
        del device_registry[device_id]
        return {"unregistered": device_id}
    raise HTTPException(status_code=404, detail="Device not found")


# ─── Chat (non-streaming) ─────────────────────────────────────────────────────

class ChatRequest(BaseModel):
    agent: str = "iris"
    chat_id: str
    message: str


class ChatResponse(BaseModel):
    chat_id: str
    response: str
    widgets: list[dict] = []


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    if req.agent not in ("iris", "claude_code", "codex"):
        raise HTTPException(status_code=400, detail=f"Unknown agent: {req.agent}")

    sessions.get_or_create(req.chat_id, agent=req.agent)

    if req.agent == "iris":
        result = await iris_agent.run(req.chat_id, req.message)
    elif req.agent == "codex":
        result = await codex_agent.run(req.chat_id, req.message)
    else:
        result = await claude_code.run(req.chat_id, req.message)

    return ChatResponse(
        chat_id=req.chat_id,
        response=result["response"],
        widgets=result.get("widgets", []),
    )


# ─── Chat (SSE streaming) ─────────────────────────────────────────────────────

class StreamChatRequest(BaseModel):
    agent: str = "iris"
    chat_id: str
    message: str


@app.post("/chat/stream")
async def chat_stream(req: StreamChatRequest):
    if req.agent not in ("iris", "claude_code", "codex"):
        raise HTTPException(status_code=400, detail=f"Unknown agent: {req.agent}")

    sessions.get_or_create(req.chat_id, agent=req.agent)

    async def generate() -> AsyncGenerator[str, None]:
        try:
            yield _sse({"kind": "status", "state": "thinking", "detail": f"Agent: {req.agent}"})

            if req.agent == "iris":
                async for event in iris_agent.run_stream(req.chat_id, req.message):
                    yield _sse(event)
            else:
                # Fallback: non-streaming agents get wrapped as a single final message
                if req.agent == "codex":
                    result = await codex_agent.run(req.chat_id, req.message)
                else:
                    result = await claude_code.run(req.chat_id, req.message)

                yield _sse({"kind": "message.final", "text": result["response"]})

                for widget in result.get("widgets", []):
                    yield _sse({
                        "kind": "widget.open",
                        "widget": {
                            "kind": "html",
                            "payload": {"html": widget.get("html", "")},
                        },
                    })

        except Exception as exc:
            yield _sse({"kind": "error", "message": str(exc)})

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


def _sse(data: dict) -> str:
    """Format a dict as an SSE data line."""
    return f"data: {json.dumps(data)}\n\n"


# ─── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "devices": len(device_registry)}

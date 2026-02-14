from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, AsyncGenerator

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

try:
    from . import sessions, iris_agent, claude_code, codex_agent
except ImportError:
    import sessions
    import iris_agent
    import claude_code
    import codex_agent

BACKEND_URL = os.environ.get("IRIS_BACKEND_URL", "http://localhost:5050")
SUPPORTED_AGENTS = {"iris", "claude_code", "codex"}

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
    widgets: list[dict] = Field(default_factory=list)


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    if req.agent not in SUPPORTED_AGENTS:
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
    if req.agent not in SUPPORTED_AGENTS:
        raise HTTPException(status_code=400, detail=f"Unknown agent: {req.agent}")

    sessions.get_or_create(req.chat_id, agent=req.agent)

    async def generate() -> AsyncGenerator[str, None]:
        async for event in _run_agent_stream(req.agent, req.chat_id, req.message):
            yield _sse(event)

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


def _validate_agent_name(agent: str) -> str:
    normalized = (agent or "").strip()
    if normalized not in SUPPORTED_AGENTS:
        raise HTTPException(status_code=400, detail=f"Unknown agent: {agent}")
    return normalized


def _resolve_agent_for_session(session_id: str, requested_agent: str | None) -> str:
    if requested_agent and requested_agent.strip():
        return _validate_agent_name(requested_agent.strip())

    session = sessions.get_session(session_id)
    stored_agent = session.get("agent") if isinstance(session, dict) else None
    if isinstance(stored_agent, str) and stored_agent in SUPPORTED_AGENTS:
        return stored_agent

    return "iris"


async def _run_agent_stream(agent: str, chat_id: str, message: str) -> AsyncGenerator[dict, None]:
    try:
        yield {"kind": "status", "state": "thinking", "detail": f"Agent: {agent}"}
        if agent == "iris":
            async for event in iris_agent.run_stream(chat_id, message):
                yield event
            return

        if agent == "codex":
            result = await codex_agent.run(chat_id, message)
        else:
            result = await claude_code.run(chat_id, message)

        yield {"kind": "message.final", "text": result["response"]}
        for widget in result.get("widgets", []):
            yield {
                "kind": "widget.open",
                "widget": {
                    "kind": "html",
                    "payload": {"html": widget.get("html", "")},
                },
            }
    except Exception as exc:
        yield {"kind": "error", "message": str(exc)}


class AgentRequestInput(BaseModel):
    type: str = "text"
    text: str


class AgentRequestDevice(BaseModel):
    id: str | None = None
    name: str | None = None
    platform: str | None = None
    app_version: str | None = None


class AgentContextMessage(BaseModel):
    role: str
    text: str


class AgentRequestContext(BaseModel):
    recent_messages: list[AgentContextMessage] = Field(default_factory=list)


class AgentRequestEnvelope(BaseModel):
    protocol_version: str = "1.0"
    kind: str = "agent.request"
    request_id: str
    timestamp: str | None = None
    workspace_id: str = "default-workspace"
    session_id: str
    device: AgentRequestDevice | None = None
    input: AgentRequestInput
    context: AgentRequestContext | None = None
    agent: str | None = None
    metadata: dict[str, Any] | None = None


@app.post("/v1/agent/stream")
async def v1_agent_stream(req: AgentRequestEnvelope, request: Request):
    session_id = req.session_id.strip()
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required")
    if req.input.type != "text":
        raise HTTPException(status_code=400, detail="input.type must be 'text'")
    message = req.input.text.strip()
    if not message:
        raise HTTPException(status_code=400, detail="input.text is required")

    metadata_agent = None
    if isinstance(req.metadata, dict):
        raw = req.metadata.get("agent")
        if isinstance(raw, str):
            metadata_agent = raw
    header_agent = request.headers.get("x-iris-agent")
    chosen_agent = _resolve_agent_for_session(session_id, req.agent or metadata_agent or header_agent)
    sessions.get_or_create(session_id, agent=chosen_agent)

    # If session is new and caller sends context, seed it once for continuity.
    if req.context and req.context.recent_messages:
        existing = sessions.get_messages(session_id)
        if not existing:
            device_id = req.device.id if req.device and req.device.id else None
            for msg in req.context.recent_messages[-20:]:
                role = msg.role.strip()
                text = msg.text.strip()
                if role in ("user", "assistant") and text:
                    sessions.add_message(
                        session_id,
                        role,
                        text,
                        message_id=f"{req.request_id}-{uuid.uuid4()}",
                        device_id=device_id,
                    )

    async def generate() -> AsyncGenerator[str, None]:
        async for event in _run_agent_stream(chosen_agent, session_id, message):
            yield _sse(event)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/v1/agent")
async def v1_agent(req: AgentRequestEnvelope, request: Request):
    session_id = req.session_id.strip()
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required")
    if req.input.type != "text":
        raise HTTPException(status_code=400, detail="input.type must be 'text'")
    message = req.input.text.strip()
    if not message:
        raise HTTPException(status_code=400, detail="input.text is required")

    metadata_agent = None
    if isinstance(req.metadata, dict):
        raw = req.metadata.get("agent")
        if isinstance(raw, str):
            metadata_agent = raw
    header_agent = request.headers.get("x-iris-agent")
    chosen_agent = _resolve_agent_for_session(session_id, req.agent or metadata_agent or header_agent)
    sessions.get_or_create(session_id, agent=chosen_agent)

    events: list[dict[str, Any]] = []
    final_text = ""
    async for event in _run_agent_stream(chosen_agent, session_id, message):
        events.append(event)
        if event.get("kind") == "message.delta":
            final_text += str(event.get("delta") or "")
        if event.get("kind") == "message.final":
            final_text = str(event.get("text") or "")

    return JSONResponse({
        "kind": "message.final",
        "request_id": req.request_id,
        "session_id": session_id,
        "agent": chosen_agent,
        "text": final_text,
        "events": events,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


# ─── Session Proxy (to Backend) ───────────────────────────────────────────────

@app.post("/sessions")
async def proxy_create_session(req: Request):
    body = await req.json()
    async with httpx.AsyncClient(base_url=BACKEND_URL, timeout=5.0) as client:
        resp = await client.post("/api/sessions", json=body)
    return resp.json()


@app.get("/sessions")
async def proxy_list_sessions(limit: int = Query(50)):
    async with httpx.AsyncClient(base_url=BACKEND_URL, timeout=5.0) as client:
        resp = await client.get("/api/sessions", params={"limit": limit})
    return resp.json()


@app.get("/sessions/{session_id}")
async def proxy_get_session(session_id: str):
    async with httpx.AsyncClient(base_url=BACKEND_URL, timeout=5.0) as client:
        resp = await client.get(f"/api/sessions/{session_id}")
    if resp.status_code == 404:
        raise HTTPException(status_code=404, detail="Session not found")
    return resp.json()


@app.get("/sessions/{session_id}/messages")
async def proxy_list_messages(session_id: str, since: str | None = Query(None), limit: int = Query(200)):
    params: dict = {"limit": limit}
    if since:
        params["since"] = since
    async with httpx.AsyncClient(base_url=BACKEND_URL, timeout=5.0) as client:
        resp = await client.get(f"/api/sessions/{session_id}/messages", params=params)
    return resp.json()


# ─── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "devices": len(device_registry)}

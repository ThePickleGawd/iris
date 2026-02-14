from __future__ import annotations

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import sessions
import iris_agent
import claude_code
import codex_agent

app = FastAPI(title="Iris Agent Server")


class ChatRequest(BaseModel):
    agent: str  # "iris", "claude_code", or "codex"
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


@app.get("/health")
async def health():
    return {"status": "ok"}

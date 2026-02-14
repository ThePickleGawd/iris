from __future__ import annotations

import json
from typing import AsyncGenerator

import anthropic

try:
    from . import sessions
    from .tools import TOOL_DEFINITIONS, TOOL_HANDLERS
except ImportError:
    import sessions
    from tools import TOOL_DEFINITIONS, TOOL_HANDLERS

client = anthropic.Anthropic()

SYSTEM_PROMPT = """You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can:
- Push interactive HTML widgets to devices using the push_widget tool
- Read screenshots from devices for visual context using the read_screenshot tool
- Read recent voice transcripts using the read_transcript tool
- Answer questions, help with tasks, and generate visual content

When generating widgets, create self-contained HTML with inline CSS and JS.
Keep widgets focused and visually polished. Prefer dark themes with clean typography."""

MODEL = "claude-sonnet-4-5-20250929"


def _convert_tools_for_anthropic(openai_tools: list[dict]) -> list[dict]:
    """Convert OpenAI-style function tool defs to Anthropic tool format."""
    result = []
    for tool in openai_tools:
        fn = tool["function"]
        result.append({
            "name": fn["name"],
            "description": fn["description"],
            "input_schema": fn["parameters"],
        })
    return result


ANTHROPIC_TOOLS = _convert_tools_for_anthropic(TOOL_DEFINITIONS)


async def run(chat_id: str, message: str) -> dict:
    sessions.add_message(chat_id, "user", message)
    history = sessions.get_messages(chat_id)

    # Build Anthropic messages from session history
    messages = []
    for msg in history:
        messages.append({"role": msg["role"], "content": msg["content"]})

    context: dict = {"widgets": [], "session_id": chat_id}

    # Tool-use loop: keep calling until we get a final text response
    while True:
        response = client.messages.create(
            model=MODEL,
            max_tokens=4096,
            system=SYSTEM_PROMPT,
            messages=messages,
            tools=ANTHROPIC_TOOLS,
        )

        # Collect the assistant response content blocks
        assistant_content = response.content
        messages.append({"role": "assistant", "content": assistant_content})

        if response.stop_reason == "tool_use":
            # Process each tool use block
            tool_results = []
            for block in assistant_content:
                if block.type != "tool_use":
                    continue

                handler = TOOL_HANDLERS.get(block.name)
                if handler:
                    result_content, _ = handler(block.input, context)
                else:
                    result_content = f"Unknown tool: {block.name}"

                # result_content may be a string or a list of content blocks
                if isinstance(result_content, list):
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result_content,
                    })
                else:
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": str(result_content),
                    })

            messages.append({"role": "user", "content": tool_results})
        else:
            # Extract final text from content blocks
            assistant_text = ""
            for block in assistant_content:
                if hasattr(block, "text"):
                    assistant_text += block.text

            sessions.add_message(chat_id, "assistant", assistant_text)
            return {
                "response": assistant_text,
                "widgets": context["widgets"],
            }


async def run_stream(chat_id: str, message: str) -> AsyncGenerator[dict, None]:
    """Streaming version of run() that yields SSE-compatible event dicts."""
    sessions.add_message(chat_id, "user", message)
    history = sessions.get_messages(chat_id)

    messages = []
    for msg in history:
        messages.append({"role": msg["role"], "content": msg["content"]})

    context: dict = {"widgets": [], "session_id": chat_id}

    while True:
        # Use streaming API
        full_text = ""
        tool_use_blocks: list[dict] = []
        current_tool: dict | None = None

        with client.messages.stream(
            model=MODEL,
            max_tokens=4096,
            system=SYSTEM_PROMPT,
            messages=messages,
            tools=ANTHROPIC_TOOLS,
        ) as stream:
            for event in stream:
                if event.type == "content_block_start":
                    block = event.content_block
                    if block.type == "tool_use":
                        current_tool = {"id": block.id, "name": block.name, "input_json": ""}
                        yield {"kind": "tool.call", "name": block.name}
                    elif block.type == "text":
                        pass  # text deltas come separately
                elif event.type == "content_block_delta":
                    delta = event.delta
                    if hasattr(delta, "text") and delta.text:
                        full_text += delta.text
                        yield {"kind": "message.delta", "delta": delta.text}
                    elif hasattr(delta, "partial_json") and delta.partial_json:
                        if current_tool is not None:
                            current_tool["input_json"] += delta.partial_json
                elif event.type == "content_block_stop":
                    if current_tool is not None:
                        try:
                            current_tool["input"] = json.loads(current_tool["input_json"])
                        except json.JSONDecodeError:
                            current_tool["input"] = {}
                        tool_use_blocks.append(current_tool)
                        current_tool = None

            # Get final message for stop_reason
            final_message = stream.get_final_message()

        if final_message.stop_reason == "tool_use":
            # Build assistant content for message history
            assistant_content = final_message.content
            messages.append({"role": "assistant", "content": assistant_content})

            # Process tool calls
            tool_results = []
            for tool_block in tool_use_blocks:
                handler = TOOL_HANDLERS.get(tool_block["name"])
                if handler:
                    result_content, _ = handler(tool_block["input"], context)
                else:
                    result_content = f"Unknown tool: {tool_block['name']}"

                yield {"kind": "tool.result", "name": tool_block["name"], "output": str(result_content) if not isinstance(result_content, list) else "image data"}

                if isinstance(result_content, list):
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tool_block["id"],
                        "content": result_content,
                    })
                else:
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tool_block["id"],
                        "content": str(result_content),
                    })

            messages.append({"role": "user", "content": tool_results})

            # Emit widget events for any widgets that were delivered
            for widget in context["widgets"]:
                if widget.get("delivered"):
                    yield {
                        "kind": "widget.open",
                        "widget": {
                            "kind": "html",
                            "id": widget.get("widget_id"),
                            "payload": {"html": widget.get("html", "")},
                        },
                    }
            # Clear so we don't re-emit on next loop
            context["widgets"] = []

            # Reset for next iteration
            full_text = ""
            tool_use_blocks = []
        else:
            # Final text response
            sessions.add_message(chat_id, "assistant", full_text)
            yield {"kind": "message.final", "text": full_text}

from __future__ import annotations

import json

from openai import OpenAI

import sessions
from tools import TOOL_DEFINITIONS, TOOL_HANDLERS

client = OpenAI()

SYSTEM_PROMPT = """You are Iris, a visual assistant that lives across a user's devices (iPad and Mac).

You can:
- Push interactive HTML widgets to devices using the push_widget tool
- Read screenshots from devices for visual context using the read_screenshot tool
- Answer questions, help with tasks, and generate visual content

When generating widgets, create self-contained HTML with inline CSS and JS.
Keep widgets focused and visually polished. Prefer dark themes with clean typography."""

MODEL = "gpt-5.2"


async def run(chat_id: str, message: str) -> dict:
    sessions.add_message(chat_id, "user", message)
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *sessions.get_messages(chat_id),
    ]

    context: dict = {"widgets": [], "session_id": chat_id}

    # Tool-use loop: keep calling until we get a text response
    while True:
        response = client.chat.completions.create(
            model=MODEL,
            messages=messages,
            tools=TOOL_DEFINITIONS,
        )

        choice = response.choices[0]

        if choice.finish_reason == "tool_calls" or choice.message.tool_calls:
            # Append the assistant message with tool calls
            messages.append(choice.message)

            for tool_call in choice.message.tool_calls:
                fn_name = tool_call.function.name
                arguments = json.loads(tool_call.function.arguments)

                handler = TOOL_HANDLERS.get(fn_name)
                if handler:
                    result_text, _ = handler(arguments, context)
                else:
                    result_text = f"Unknown tool: {fn_name}"

                messages.append({
                    "role": "tool",
                    "tool_call_id": tool_call.id,
                    "content": result_text,
                })
        else:
            # Text response — we're done
            assistant_text = choice.message.content or ""
            sessions.add_message(chat_id, "assistant", assistant_text)
            return {
                "response": assistant_text,
                "widgets": context["widgets"],
            }

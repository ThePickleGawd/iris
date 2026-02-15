import {
  AgentMessage,
  AgentRequestEnvelope,
  AgentTransportSettings,
  buildAgentRequestEnvelope,
  normalizeIncomingEvent
} from "./agentProtocol"
import type { WidgetSpec } from "./widgetProtocol"

export interface AgentStreamCallbacks {
  onFinal: (text: string) => void
  onStatus?: (state: string, detail?: string) => void
  onReasoning?: (text: string) => void
  onToolCall?: (name: string, input?: unknown) => void
  onToolResult?: (name: string, data?: { ok?: boolean; summary?: string; output?: unknown }) => void
  onWidgetOpen?: (widget: WidgetSpec) => void
  onSessionName?: (name: string) => void
  onError: (message: string) => void
}

export async function requestAgentResponse(params: {
  settings: AgentTransportSettings
  requestId: string
  message: string
  history: AgentMessage[]
  callbacks: AgentStreamCallbacks
  signal?: AbortSignal
}): Promise<void> {
  return requestViaBackend(params)
}

function parseSSEBlock(block: string): { type: string; data: Record<string, unknown> } | null {
  let eventType = ""
  let dataStr = ""
  for (const line of block.split("\n")) {
    if (line.startsWith("event: ")) {
      eventType = line.slice(7).trim()
    } else if (line.startsWith("data: ")) {
      dataStr += line.slice(6)
    }
  }
  if (!eventType || !dataStr) return null
  try {
    const data = JSON.parse(dataStr)
    return { type: eventType, data }
  } catch {
    return null
  }
}

async function requestViaBackend(params: {
  settings: AgentTransportSettings
  requestId: string
  message: string
  history: AgentMessage[]
  callbacks: AgentStreamCallbacks
  signal?: AbortSignal
}): Promise<void> {
  const { settings, requestId, message, history, callbacks, signal } = params

  const envelope: AgentRequestEnvelope = buildAgentRequestEnvelope({
    requestId,
    message,
    history,
    settings
  })

  const base = settings.backendBaseUrl.replace(/\/$/, "")
  const path = settings.backendPath.startsWith("/")
    ? settings.backendPath
    : `/${settings.backendPath}`
  const url = `${base}${path}`

  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "text/event-stream"
  }

  if (settings.authToken) {
    headers.authorization = `Bearer ${settings.authToken}`
  }

  const response = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({ ...envelope, stream: true }),
    signal
  })

  if (!response.ok) {
    const body = await response.text()
    callbacks.onError(`Backend error ${response.status}: ${body || response.statusText}`)
    return
  }

  const contentType = response.headers.get("content-type") || ""

  // SSE streaming response
  if (contentType.includes("text/event-stream") && response.body) {
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    let finalText = ""

    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })

        // Parse SSE events from buffer (split on double newline)
        while (buffer.includes("\n\n")) {
          const idx = buffer.indexOf("\n\n")
          const block = buffer.slice(0, idx)
          buffer = buffer.slice(idx + 2)

          const event = parseSSEBlock(block)
          if (!event) continue

          switch (event.type) {
            case "status":
              callbacks.onStatus?.(
                String(event.data.state || "unknown"),
                event.data.detail ? String(event.data.detail) : undefined
              )
              break
            case "reasoning":
              callbacks.onReasoning?.(String(event.data.text || ""))
              break
            case "tool.call":
              callbacks.onToolCall?.(String(event.data.name || "unknown"), event.data.input)
              break
            case "tool.result":
              callbacks.onToolResult?.(String(event.data.name || "unknown"), {
                ok: typeof event.data.ok === "boolean" ? event.data.ok : undefined,
                summary: typeof event.data.summary === "string" ? event.data.summary : undefined,
                output: event.data.output
              })
              break
            case "widget.open": {
              const normalized = normalizeIncomingEvent({ kind: "widget.open", ...event.data })
              if (normalized && normalized.kind === "widget.open") {
                callbacks.onWidgetOpen?.(normalized.widget)
              }
              break
            }
            case "final": {
              finalText = String(event.data.text || "")
              // Emit session name from final payload
              if (typeof event.data.session_name === "string" && event.data.session_name.trim() && event.data.session_name !== "Untitled") {
                callbacks.onSessionName?.(String(event.data.session_name))
              }
              // Process any widget.open events from the final payload
              const events = Array.isArray(event.data.events) ? event.data.events : []
              for (const rawEvent of events) {
                const normalized = normalizeIncomingEvent(rawEvent)
                if (!normalized) continue
                if (normalized.kind === "widget.open") {
                  callbacks.onWidgetOpen?.(normalized.widget)
                }
              }
              break
            }
            case "done":
              break
            case "error":
              callbacks.onError(String(event.data.message || "Unknown backend error"))
              return
          }
        }
      }
    } catch (err) {
      callbacks.onError(`Stream read error: ${err}`)
      return
    }

    if (finalText) {
      callbacks.onFinal(finalText)
    } else {
      callbacks.onError("Backend stream ended without final response")
    }
    return
  }

  // Fallback: JSON response (non-streaming)
  let payload: unknown
  try {
    payload = await response.json()
  } catch {
    callbacks.onError("Backend returned invalid JSON")
    return
  }

  const root = payload as Record<string, unknown>
  const events = Array.isArray(root.events) ? root.events : []
  let finalText = typeof root.text === "string" ? root.text : ""
  let emittedFinal = false

  if (typeof root.session_name === "string" && root.session_name.trim() && root.session_name !== "Untitled") {
    callbacks.onSessionName?.(root.session_name as string)
  }

  for (const rawEvent of events) {
    const event = normalizeIncomingEvent(rawEvent)
    if (!event) continue
    switch (event.kind) {
      case "status":
        callbacks.onStatus?.(event.state, event.detail)
        break
      case "reasoning":
        callbacks.onReasoning?.(event.text)
        break
      case "tool.call":
        callbacks.onToolCall?.(event.name, event.input)
        break
      case "tool.result":
        callbacks.onToolResult?.(event.name, { ok: event.ok, summary: event.summary, output: event.output })
        break
      case "widget.open":
        callbacks.onWidgetOpen?.(event.widget)
        break
      case "message.final":
        finalText = event.text
        emittedFinal = true
        break
      case "error":
        callbacks.onError(event.message)
        return
    }
  }

  if (emittedFinal || finalText) {
    callbacks.onFinal(finalText)
    return
  }

  callbacks.onError("Backend returned no final response text")
}

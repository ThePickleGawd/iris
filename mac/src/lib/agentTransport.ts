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
  onToolCall?: (name: string, input?: unknown) => void
  onToolResult?: (name: string, output?: unknown) => void
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
}): Promise<void> {
  return requestViaBackend(params)
}

async function requestViaBackend(params: {
  settings: AgentTransportSettings
  requestId: string
  message: string
  history: AgentMessage[]
  callbacks: AgentStreamCallbacks
}): Promise<void> {
  const { settings, requestId, message, history, callbacks } = params

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
    accept: "application/json"
  }

  if (settings.authToken) {
    headers.authorization = `Bearer ${settings.authToken}`
  }

  const response = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(envelope)
  })

  if (!response.ok) {
    const body = await response.text()
    callbacks.onError(`Backend error ${response.status}: ${body || response.statusText}`)
    return
  }

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

  // Emit auto-generated session name if present
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
      case "tool.call":
        callbacks.onToolCall?.(event.name, event.input)
        break
      case "tool.result":
        callbacks.onToolResult?.(event.name, event.output)
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

import {
  AgentMessage,
  AgentRequestEnvelope,
  AgentStreamEvent,
  AgentTransportSettings,
  buildAgentRequestEnvelope,
  normalizeIncomingEvent,
  splitPotentialJsonFrames
} from "./agentProtocol"
import type { WidgetSpec } from "./widgetProtocol"

export interface AgentStreamCallbacks {
  onDelta: (chunk: string) => void
  onFinal: (text: string) => void
  onStatus?: (state: string, detail?: string) => void
  onToolCall?: (name: string, input?: unknown) => void
  onToolResult?: (name: string, output?: unknown) => void
  onWidgetOpen?: (widget: WidgetSpec) => void
  onError: (message: string) => void
}

export async function streamAgentResponse(params: {
  settings: AgentTransportSettings
  requestId: string
  message: string
  history: AgentMessage[]
  callbacks: AgentStreamCallbacks
}): Promise<void> {
  const { settings } = params
  if (settings.mode === "backend") {
    return streamViaBackend(params)
  }
  return streamViaDirect(params)
}

async function streamViaDirect(params: {
  requestId: string
  message: string
  callbacks: AgentStreamCallbacks
}): Promise<void> {
  const { requestId, message, callbacks } = params

  await new Promise<void>(async (resolve) => {
    let full = ""

    let cleanupChunk = () => {}
    let cleanupDone = () => {}
    let cleanupError = () => {}

    cleanupChunk = window.electronAPI.onClaudeChatStreamChunk((data) => {
      if (data.requestId !== requestId) return
      full += data.chunk
      callbacks.onDelta(data.chunk)
    })

    cleanupDone = window.electronAPI.onClaudeChatStreamDone((data) => {
      if (data.requestId !== requestId) return
      cleanupChunk()
      cleanupDone()
      cleanupError()
      callbacks.onFinal(data.text || full)
      resolve()
    })

    cleanupError = window.electronAPI.onClaudeChatStreamError((data) => {
      if (data.requestId !== requestId) return
      cleanupChunk()
      cleanupDone()
      cleanupError()
      callbacks.onError(data.error || "Unknown stream error")
      resolve()
    })

    const start = await window.electronAPI.startClaudeChatStream(requestId, message)
    if (!start.success) {
      cleanupChunk()
      cleanupDone()
      cleanupError()
      callbacks.onError(start.error || "Failed to start local stream")
      resolve()
    }
  })
}

async function streamViaBackend(params: {
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
  const path = settings.backendStreamPath.startsWith("/")
    ? settings.backendStreamPath
    : `/${settings.backendStreamPath}`
  const url = `${base}${path}`

  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "text/event-stream, application/x-ndjson, application/json"
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

  if (!response.body) {
    callbacks.onError("Backend stream body is empty")
    return
  }

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ""
  let finalText = ""
  let emittedFinal = false

  while (true) {
    const { done, value } = await reader.read()
    if (done) break

    buffer += decoder.decode(value, { stream: true })

    const lines = buffer.split("\n")
    buffer = lines.pop() || ""

    for (const rawLine of lines) {
      const frames = splitPotentialJsonFrames(rawLine)
      for (const frame of frames) {
        let parsed: unknown = null
        try {
          parsed = JSON.parse(frame)
        } catch {
          continue
        }

        const event = normalizeIncomingEvent(parsed)
        if (!event) continue

        handleAgentEvent(event, callbacks, {
          appendFinalText: (delta) => {
            finalText += delta
          },
          setFinalText: (text) => {
            finalText = text
            emittedFinal = true
          }
        })
      }
    }
  }

  if (buffer.trim()) {
    const frames = splitPotentialJsonFrames(buffer)
    for (const frame of frames) {
      try {
        const parsed = JSON.parse(frame)
        const event = normalizeIncomingEvent(parsed)
        if (!event) continue
        handleAgentEvent(event, callbacks, {
          appendFinalText: (delta) => {
            finalText += delta
          },
          setFinalText: (text) => {
            finalText = text
            emittedFinal = true
          }
        })
      } catch {
        // ignore trailing non-JSON frame
      }
    }
  }

  if (!emittedFinal && finalText) {
    callbacks.onFinal(finalText)
  }
}

function handleAgentEvent(
  event: AgentStreamEvent,
  callbacks: AgentStreamCallbacks,
  acc: { appendFinalText: (delta: string) => void; setFinalText: (text: string) => void }
) {
  switch (event.kind) {
    case "status":
      callbacks.onStatus?.(event.state, event.detail)
      break
    case "message.delta":
      acc.appendFinalText(event.delta)
      callbacks.onDelta(event.delta)
      break
    case "message.final":
      acc.setFinalText(event.text)
      callbacks.onFinal(event.text)
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
    case "error":
      callbacks.onError(event.message)
      break
  }
}

import { normalizeWidgetSpec, type WidgetSpec } from "./widgetProtocol"

export type AgentTransportMode = "backend"

export interface AgentTransportSettings {
  mode: AgentTransportMode
  backendBaseUrl: string
  backendPath: string
  model: string
  workspaceId: string
  sessionId: string
  claudeCodeConversationId?: string
  codexConversationId?: string
  authToken: string
}

export interface AgentMessage {
  role: "user" | "assistant"
  text: string
}

export interface AgentRequestEnvelope {
  protocol_version: "1.0"
  kind: "agent.request"
  request_id: string
  timestamp: string
  workspace_id: string
  session_id: string
  device: {
    id: string
    name: string
    platform: string
    app_version: string
  }
  input: {
    type: "text"
    text: string
  }
  context: {
    recent_messages: Array<{ role: "user" | "assistant"; text: string }>
  }
  model: string
  metadata: {
    model: string
    agent?: string
    claude_code_conversation_id?: string
    codex_conversation_id?: string
  }
}

export type AgentStreamEvent =
  | { kind: "status"; state: string; detail?: string }
  | { kind: "message.final"; text: string }
  | { kind: "tool.call"; name: string; input?: unknown }
  | { kind: "tool.result"; name: string; output?: unknown }
  | { kind: "widget.open"; widget: WidgetSpec }
  | { kind: "error"; message: string }

export function createRequestId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
}

export function buildAgentRequestEnvelope(params: {
  requestId: string
  message: string
  history: AgentMessage[]
  settings: AgentTransportSettings
}): AgentRequestEnvelope {
  const { requestId, message, history, settings } = params
  return {
    protocol_version: "1.0",
    kind: "agent.request",
    request_id: requestId,
    timestamp: new Date().toISOString(),
    workspace_id: settings.workspaceId || "default-workspace",
    session_id: settings.sessionId || "default-session",
    device: {
      id: getOrCreateDeviceId(),
      name: "iris-mac",
      platform: navigator.platform || "unknown",
      app_version: "0.1.0"
    },
    input: {
      type: "text",
      text: message
    },
    context: {
      recent_messages: history.slice(-20).map((m) => ({ role: m.role, text: m.text }))
    },
    model: settings.model || "gpt-5.2",
    metadata: {
      model: settings.model || "gpt-5.2",
      agent: settings.model || "gpt-5.2",
      ...(settings.claudeCodeConversationId
        ? { claude_code_conversation_id: settings.claudeCodeConversationId }
        : {}),
      ...(settings.codexConversationId
        ? { codex_conversation_id: settings.codexConversationId }
        : {})
    }
  }
}

function getOrCreateDeviceId(): string {
  try {
    const key = "iris_device_id"
    const existing = localStorage.getItem(key)
    if (existing) return existing
    const created = `device-${Math.random().toString(36).slice(2, 10)}`
    localStorage.setItem(key, created)
    return created
  } catch {
    return `device-${Math.random().toString(36).slice(2, 10)}`
  }
}

export function normalizeIncomingEvent(raw: unknown): AgentStreamEvent | null {
  if (!raw || typeof raw !== "object") return null
  const obj = raw as Record<string, unknown>

  const kind = typeof obj.kind === "string" ? obj.kind : typeof obj.type === "string" ? obj.type : ""

  if (kind === "status") {
    return {
      kind: "status",
      state: String(obj.state || "unknown"),
      detail: obj.detail ? String(obj.detail) : undefined
    }
  }

  if (kind === "message.final") {
    const text = String(obj.text ?? "")
    return { kind: "message.final", text }
  }

  if (kind === "tool.call") {
    return {
      kind: "tool.call",
      name: String(obj.name || "unknown"),
      input: obj.input
    }
  }

  if (kind === "tool.result") {
    return {
      kind: "tool.result",
      name: String(obj.name || "unknown"),
      output: obj.output
    }
  }

  if (kind === "widget.open") {
    const normalized = normalizeWidgetSpec(obj.widget ?? obj.spec ?? obj.payload ?? obj)
    if (!normalized) return null
    return {
      kind: "widget.open",
      widget: normalized
    }
  }

  if (kind === "error") {
    return {
      kind: "error",
      message: String(obj.message || obj.error || "Unknown backend error")
    }
  }

  if (typeof obj.text === "string") {
    return { kind: "message.final", text: obj.text }
  }
  if (typeof obj.error === "string") {
    return { kind: "error", message: obj.error }
  }

  return null
}

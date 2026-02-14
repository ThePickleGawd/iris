import React, { useCallback, useEffect, useRef, useState } from "react"
import { ChevronDown, ChevronUp, Plus, SendHorizontal, X } from "lucide-react"
import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"
import remarkMath from "remark-math"
import rehypeKatex from "rehype-katex"
import "katex/dist/katex.min.css"
import {
  Toast,
  ToastTitle,
  ToastDescription,
  ToastVariant,
  ToastMessage
} from "../components/ui/toast"
import { createRequestId } from "../lib/agentProtocol"
import type { AgentTransportSettings } from "../lib/agentProtocol"
import { streamAgentResponse } from "../lib/agentTransport"
import { extractWidgetBlocks, normalizeWidgetSpec } from "../lib/widgetProtocol"

interface ChatMessage {
  role: "user" | "assistant"
  text: string
  _id?: string
}

interface SessionInfo {
  id: string
  agent: string
  name: string
}

const agentChoices = [
  { id: "iris", name: "Iris", subtitle: "Widget + screenshot workflows" },
  { id: "codex", name: "Codex", subtitle: "Coding-focused model" },
  { id: "claude_code", name: "Claude Code", subtitle: "Claude coding agent" },
] as const

const Queue: React.FC = () => {
  const [toastOpen, setToastOpen] = useState(false)
  const [toastMessage, setToastMessage] = useState<ToastMessage>({
    title: "",
    description: "",
    variant: "neutral"
  })
  const [isExpanded, setIsExpanded] = useState(false)
  const [chatInput, setChatInput] = useState("")
  const [chatMessages, setChatMessages] = useState<ChatMessage[]>([])
  const [chatLoading, setChatLoading] = useState(false)
  const [showAgentPicker, setShowAgentPicker] = useState(false)

  const [backendBaseUrl] = useState("http://localhost:8000")
  const [backendStreamPath] = useState("/v1/agent/stream")
  const [workspaceId] = useState("default-workspace")
  const [sessionId] = useState("default-session")
  const [backendAuthToken] = useState("")

  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [currentSession, setCurrentSession] = useState<SessionInfo | null>(null)

  const contentRef = useRef<HTMLDivElement>(null)
  const messageListRef = useRef<HTMLDivElement>(null)
  const chatInputRef = useRef<HTMLInputElement>(null)
  const activeStreamRequestRef = useRef<string | null>(null)

  const showToast = (title: string, description: string, variant: ToastVariant) => {
    setToastMessage({ title, description, variant })
    setToastOpen(true)
  }

  const openWidget = async (rawSpec: unknown) => {
    const spec = normalizeWidgetSpec(rawSpec)
    if (!spec) return false
    try {
      const result = await window.electronAPI.openWidget(spec)
      if (!result.success && result.error) {
        console.warn("Failed to open widget:", result.error)
      }
      return result.success
    } catch (error) {
      console.warn("Failed to open widget:", error)
      return false
    }
  }

  const applyFinalAssistantOutput = async (text: string, onText?: (clean: string) => void) => {
    const { cleanText, widgets } = extractWidgetBlocks(text || "")
    if (cleanText) {
      if (onText) onText(cleanText)
    } else if (widgets.length > 0) {
      if (onText) onText("Opened widget output.")
    } else {
      if (onText) onText(text)
    }

    for (const widget of widgets) {
      await openWidget(widget)
    }
  }

  const refreshSessions = useCallback(async () => {
    try {
      const data = await window.electronAPI.getSessions()
      setSessions((data?.items || []) as SessionInfo[])
    } catch {
      // Session API unavailable is non-fatal.
    }
  }, [])

  const handleSelectSession = useCallback(async (session: SessionInfo) => {
    const info = { id: session.id, agent: session.agent, name: session.name }
    setCurrentSession(info)
    setChatMessages([])
    setChatLoading(true)

    try {
      await window.electronAPI.setCurrentSession(info)
      const data = await window.electronAPI.getSessionMessages(session.id)
      const messages = (data?.items || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id
      }))
      setChatMessages(messages)
    } catch {
      // Non-fatal
    } finally {
      setChatLoading(false)
    }
  }, [])

  const handleNewChat = useCallback(async (agent = "iris") => {
    const id = `mac-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`
    const name = `Chat ${new Date().toLocaleTimeString()}`

    try {
      await window.electronAPI.createSession({ id, name, agent })
      const info = { id, name, agent }
      setCurrentSession(info)
      setChatMessages([])
      await refreshSessions()
      return info
    } catch {
      return null
    }
  }, [refreshSessions])

  const handleAgentPick = useCallback(async (agentId: string) => {
    setShowAgentPicker(false)
    await handleNewChat(agentId)
  }, [handleNewChat])

  const sendChatMessage = async (message: string) => {
    const trimmed = message.trim()
    if (!trimmed) return

    let selectedSession = currentSession
    if (!selectedSession) {
      selectedSession = await handleNewChat()
      if (!selectedSession) {
        showToast("Session Error", "Could not create a chat session.", "error")
        return
      }
    }

    const requestId = createRequestId()
    activeStreamRequestRef.current = requestId
    setChatMessages((msgs) => [...msgs, { role: "user", text: trimmed }, { role: "assistant", text: "" }])
    setChatLoading(true)

    const appendChunk = (chunk: string) => {
      setChatMessages((msgs) => {
        if (msgs.length === 0) return msgs
        const updated = [...msgs]
        const idx = updated.length - 1
        updated[idx] = { ...updated[idx], text: (updated[idx].text || "") + chunk }
        return updated
      })
    }

    const setAssistantText = (text: string) => {
      setChatMessages((msgs) => {
        if (msgs.length === 0) return msgs
        const updated = [...msgs]
        const idx = updated.length - 1
        updated[idx] = { ...updated[idx], text }
        return updated
      })
    }

    const settings: AgentTransportSettings = {
      mode: "backend",
      backendBaseUrl: backendBaseUrl.trim(),
      backendStreamPath: backendStreamPath.trim() || "/v1/agent/stream",
      workspaceId: selectedSession?.id || workspaceId,
      sessionId: selectedSession?.id || sessionId,
      authToken: backendAuthToken
    }

    try {
      if (!settings.backendBaseUrl) {
        throw new Error("Backend URL is required")
      }

      await streamAgentResponse({
        settings,
        requestId,
        message: trimmed,
        history: chatMessages,
        callbacks: {
          onDelta: (chunk) => {
            if (activeStreamRequestRef.current !== requestId) return
            appendChunk(chunk)
          },
          onFinal: (text) => {
            if (activeStreamRequestRef.current !== requestId) return
            if (text) {
              void applyFinalAssistantOutput(text, (clean) => setAssistantText(clean))
            }
          },
          onStatus: () => {},
          onToolCall: () => {},
          onToolResult: () => {},
          onWidgetOpen: (widget) => {
            if (activeStreamRequestRef.current !== requestId) return
            void openWidget(widget)
          },
          onError: (msg) => {
            if (activeStreamRequestRef.current !== requestId) return
            setAssistantText(`Error: ${msg}`)
          }
        }
      })
    } catch (error: any) {
      setAssistantText(`Error: ${error?.message || String(error)}`)
    } finally {
      activeStreamRequestRef.current = null
      setChatLoading(false)
      chatInputRef.current?.focus()
    }
  }

  const handleChatSend = async () => {
    if (!chatInput.trim()) return
    const message = chatInput
    setChatInput("")
    await sendChatMessage(message)
  }

  useEffect(() => {
    refreshSessions()
    const interval = setInterval(refreshSessions, 10_000)
    return () => clearInterval(interval)
  }, [refreshSessions])

  useEffect(() => {
    const cleanup = window.electronAPI.onSessionMessagesUpdate((data: { sessionId: string; messages: any[] }) => {
      if (!currentSession || data.sessionId !== currentSession.id) return

      const incoming = (data.messages || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id
      }))

      if (incoming.length === 0) return

      setChatMessages((prev) => {
        const existing = new Set(prev.map((m) => m._id).filter(Boolean))
        const toAdd = incoming.filter((m) => !existing.has(m._id))
        return toAdd.length > 0 ? [...prev, ...toAdd] : prev
      })
    })

    return cleanup
  }, [currentSession])

  useEffect(() => {
    if (!messageListRef.current) return
    messageListRef.current.scrollTop = messageListRef.current.scrollHeight
  }, [chatMessages, chatLoading])

  useEffect(() => {
    const updateDimensions = () => {
      if (!contentRef.current) return
      window.electronAPI.updateContentDimensions({
        width: contentRef.current.scrollWidth,
        height: contentRef.current.scrollHeight
      })
    }

    const resizeObserver = new ResizeObserver(updateDimensions)
    if (contentRef.current) resizeObserver.observe(contentRef.current)
    updateDimensions()

    return () => {
      resizeObserver.disconnect()
      activeStreamRequestRef.current = null
    }
  }, [isExpanded, chatMessages.length, chatLoading])

  return (
    <div ref={contentRef} className="iris-surface select-none">
      <Toast open={toastOpen} onOpenChange={setToastOpen} variant={toastMessage.variant} duration={3000}>
        <ToastTitle>{toastMessage.title}</ToastTitle>
        <ToastDescription>{toastMessage.description}</ToastDescription>
      </Toast>

      {showAgentPicker && (
        <div className="iris-agent-picker-backdrop interactive" onClick={() => setShowAgentPicker(false)}>
          <div className="iris-agent-picker" onClick={(e) => e.stopPropagation()}>
            <div className="iris-agent-picker-title">New Chat</div>
            {agentChoices.map((choice) => (
              <button
                key={choice.id}
                type="button"
                className="iris-agent-picker-option interactive"
                onClick={() => handleAgentPick(choice.id)}
              >
                <span className="iris-agent-picker-name">{choice.name}</span>
                <span className="iris-agent-picker-sub">{choice.subtitle}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {!isExpanded ? (
        /* Collapsed: compact bar with convo name and close */
        <div className="iris-floating-bar draggable-area">
          <button
            type="button"
            className="iris-toggle interactive"
            onClick={() => window.electronAPI.toggleWindow()}
            aria-label="Close"
          >
            <X size={13} />
          </button>
          <span className="iris-bar-title interactive" onClick={() => setIsExpanded(true)}>
            {currentSession?.name || "Iris"}
          </span>
          <button
            type="button"
            className="iris-toggle interactive"
            onClick={() => setIsExpanded(true)}
            aria-label="Expand"
          >
            <ChevronDown size={13} />
          </button>
        </div>
      ) : (
        /* Expanded: shell with dark background, overflow:hidden is safe here */
        <div className="iris-shell draggable-area">
          <header className="iris-bar draggable-area">
            <button
              type="button"
              className="iris-tab iris-tab-new interactive"
              onClick={() => setShowAgentPicker(true)}
              title="New chat"
            >
              <Plus size={11} />
            </button>
            <span className="iris-bar-title">
              {currentSession?.name || "Iris"}
            </span>
            <button
              type="button"
              className="iris-toggle interactive"
              onClick={() => setIsExpanded(false)}
              aria-label="Collapse"
            >
              <ChevronUp size={13} />
            </button>
          </header>

          <main className="iris-chat">
            <div ref={messageListRef} className="iris-messages interactive">
              {chatMessages.length === 0 ? (
                <div className="iris-empty">Start a conversation</div>
              ) : (
                chatMessages.map((msg, idx) => (
                  <div key={idx} className={`iris-msg ${msg.role}`}>
                    <div className="iris-msg-bubble">
                      {msg.role === "assistant" ? (
                        msg.text ? (
                          <ReactMarkdown
                            className="iris-markdown"
                            remarkPlugins={[remarkGfm, remarkMath]}
                            rehypePlugins={[rehypeKatex]}
                          >
                            {msg.text}
                          </ReactMarkdown>
                        ) : (
                          <div className="iris-thinking">
                            <span />
                            <span />
                            <span />
                          </div>
                        )
                      ) : (
                        msg.text
                      )}
                    </div>
                  </div>
                ))
              )}
            </div>

            <form
              className="iris-compose interactive"
              onSubmit={(e) => {
                e.preventDefault()
                handleChatSend()
              }}
            >
              <input
                ref={chatInputRef}
                className="iris-input"
                placeholder="Message..."
                value={chatInput}
                onChange={(e) => setChatInput(e.target.value)}
                disabled={chatLoading}
              />
              <button
                type="submit"
                className="iris-send"
                disabled={chatLoading || !chatInput.trim()}
                aria-label="Send"
              >
                <SendHorizontal size={14} />
              </button>
            </form>
          </main>
        </div>
      )}
    </div>
  )
}

export default Queue

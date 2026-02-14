import React, { useCallback, useEffect, useRef, useState } from "react"
import { ChevronDown, ChevronUp, Plus, SendHorizontal } from "lucide-react"
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

  const handleNewChat = useCallback(async () => {
    const id = `mac-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`
    const name = `Chat ${new Date().toLocaleTimeString()}`
    const agent = "iris"

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
    <div ref={contentRef} className="assistant-surface select-none">
      <Toast open={toastOpen} onOpenChange={setToastOpen} variant={toastMessage.variant} duration={3000}>
        <ToastTitle>{toastMessage.title}</ToastTitle>
        <ToastDescription>{toastMessage.description}</ToastDescription>
      </Toast>

      <div className={`compact-shell liquid-glass ${isExpanded ? "shell-expanded" : "shell-collapsed"}`}>
        <header className="compact-header draggable-area">
          <div className="session-tabs interactive">
            {sessions.map((s) => (
              <button
                key={s.id}
                type="button"
                className={`session-tab ${currentSession?.id === s.id ? "session-tab-active" : ""}`}
                onClick={() => handleSelectSession(s)}
                title={s.name}
              >
                {s.name}
              </button>
            ))}
            <button
              type="button"
              className="session-tab session-tab-new"
              onClick={handleNewChat}
              title="New tab"
            >
              <Plus size={12} />
              New
            </button>
          </div>
        </header>

        <button
          type="button"
          className="expand-toggle interactive"
          onClick={() => setIsExpanded((value) => !value)}
          aria-label={isExpanded ? "Collapse" : "Expand"}
        >
          {isExpanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
        </button>

        {isExpanded && (
          <section className="chat-panel">
            <div ref={messageListRef} className="chat-log">
              {chatMessages.length === 0 ? (
                <div className="chat-empty">Start chatting.</div>
              ) : (
                chatMessages.map((msg, idx) => (
                  <div key={idx} className={`chat-row ${msg.role === "user" ? "chat-row-user" : "chat-row-assistant"}`}>
                    <div className={`chat-bubble ${msg.role === "user" ? "message-user" : "message-assistant"}`}>
                      {msg.role === "assistant" ? (
                        <ReactMarkdown
                          className="message-markdown"
                          remarkPlugins={[remarkGfm, remarkMath]}
                          rehypePlugins={[rehypeKatex]}
                        >
                          {msg.text}
                        </ReactMarkdown>
                      ) : (
                        msg.text
                      )}
                    </div>
                  </div>
                ))
              )}
              {chatLoading && (
                <div className="chat-row chat-row-assistant">
                  <div className="chat-bubble message-assistant">Thinking...</div>
                </div>
              )}
            </div>

            <form
              className="chat-compose"
              onSubmit={(e) => {
                e.preventDefault()
                handleChatSend()
              }}
            >
              <input
                ref={chatInputRef}
                className="chat-input"
                placeholder="Type a message..."
                value={chatInput}
                onChange={(e) => setChatInput(e.target.value)}
                disabled={chatLoading}
              />
              <button
                type="submit"
                className="chat-send"
                disabled={chatLoading || !chatInput.trim()}
                aria-label="Send"
              >
                <SendHorizontal size={16} />
              </button>
            </form>
          </section>
        )}
      </div>
    </div>
  )
}

export default Queue

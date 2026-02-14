import React, { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { ChevronDown, ChevronUp, MessageSquare, Plus, SendHorizontal, X } from "lucide-react"
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
import { requestAgentResponse } from "../lib/agentTransport"
import { extractWidgetBlocks, normalizeWidgetSpec } from "../lib/widgetProtocol"

interface ToolCallInfo {
  name: string
  target?: string
  widget_id?: string
  width?: number
  height?: number
}

interface ChatMessage {
  role: "user" | "assistant"
  text: string
  _id?: string
  toolCalls?: ToolCallInfo[]
}

interface SessionInfo {
  id: string
  model: string
  name: string
  metadata?: {
    claude_code_conversation_id?: string
    claude_code_cwd?: string
    codex_conversation_id?: string
    codex_cwd?: string
  }
}

function formatRelativeTime(iso: string): string {
  const d = new Date(iso)
  const now = Date.now()
  const diff = now - d.getTime()
  if (diff < 0) return "now"
  const mins = Math.floor(diff / 60_000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h`
  const days = Math.floor(hrs / 24)
  if (days < 7) return `${days}d`
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
}

const modelChoices = [
  { id: "gpt-5.2", name: "GPT-5.2", subtitle: "OpenAI general-purpose model" },
  { id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", subtitle: "Best for screenshot and widget workflows" },
  { id: "claude_code", name: "Claude Code", subtitle: "Link this Iris session to a Claude Code conversation" },
  { id: "codex", name: "Codex", subtitle: "Link this Iris session to a Codex conversation" },
  { id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", subtitle: "Fast multimodal model for lightweight tasks" },
] as const

const CLAUDE_CODE_MODEL_ID = "claude_code"
const CODEX_MODEL_ID = "codex"

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
  const [showModelPicker, setShowModelPicker] = useState(false)
  const [showClaudeCodeSessionPicker, setShowClaudeCodeSessionPicker] = useState(false)
  const [showCodexSessionPicker, setShowCodexSessionPicker] = useState(false)
  const [showSessionDrawer, setShowSessionDrawer] = useState(false)

  const [backendBaseUrl] = useState("http://localhost:8000")
  const [backendPath] = useState("/v1/agent")
  const [workspaceId] = useState("default-workspace")
  const [sessionId] = useState("default-session")
  const [backendAuthToken] = useState("")

  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [claudeCodeSessions, setClaudeCodeSessions] = useState<Array<{
    id: string
    title: string
    timestamp?: string
    cwd?: string
  }>>([])
  const [codexSessions, setCodexSessions] = useState<Array<{
    id: string
    title: string
    timestamp?: string
    cwd?: string
  }>>([])
  const [currentSession, setCurrentSession] = useState<SessionInfo | null>(null)

  const contentRef = useRef<HTMLDivElement>(null)
  const messageListRef = useRef<HTMLDivElement>(null)
  const chatInputRef = useRef<HTMLInputElement>(null)
  const activeStreamRequestRef = useRef<string | null>(null)
  const sessionToggleDragRef = useRef<{
    moved: boolean
    startX: number
    startY: number
    lastX: number
    lastY: number
    moveHandler: (event: MouseEvent) => void
    upHandler: () => void
  } | null>(null)

  const showToast = (title: string, description: string, variant: ToastVariant) => {
    setToastMessage({ title, description, variant })
    setToastOpen(true)
  }

  const openWidget = async (rawSpec: unknown) => {
    const spec = normalizeWidgetSpec(rawSpec)
    if (!spec) return false
    try {
      const result = await window.electronAPI.openWidget(spec)
      if (result.success && result.id) {
        window.electronAPI.registerRenderedWidget(result.id).catch(() => {})
      }
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
      const items = (data?.items || []) as SessionInfo[]
      setSessions(items)

      // Auto-select the most recently updated session if none is selected
      setCurrentSession((prev) => {
        if (prev) return prev
        if (items.length === 0) return null
        const sorted = [...items].sort((a, b) => {
          const ta = (a as any).updated_at || (a as any).created_at || ""
          const tb = (b as any).updated_at || (b as any).created_at || ""
          return tb.localeCompare(ta)
        })
        const best = sorted[0]
        window.electronAPI.setCurrentSession({ id: best.id, model: best.model, name: best.name, metadata: best.metadata }).catch(() => {})
        return { id: best.id, model: best.model, name: best.name, metadata: best.metadata }
      })
    } catch {
      // Session API unavailable is non-fatal.
    }
  }, [])

  const handleSelectSession = useCallback(async (session: SessionInfo) => {
    const info = { id: session.id, model: session.model, name: session.name, metadata: session.metadata }
    setCurrentSession(info)
    setChatMessages([])
    setChatLoading(true)

    try {
      await window.electronAPI.setCurrentSession(info)
      const data = await window.electronAPI.getSessionMessages(session.id)
      const messages = (data?.items || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id,
        ...(m.tool_calls?.length ? { toolCalls: m.tool_calls } : {})
      }))
      setChatMessages(messages)
    } catch {
      // Non-fatal
    } finally {
      setChatLoading(false)
    }
  }, [])

  const handleNewChat = useCallback(async (model = "gpt-5.2", metadata?: SessionInfo["metadata"]) => {
    const id = crypto.randomUUID().toUpperCase()
    const name = `Chat ${new Date().toLocaleTimeString()}`

    try {
      await window.electronAPI.createSession({ id, name, model, metadata })
      const info = { id, name, model, metadata }
      setCurrentSession(info)
      setChatMessages([])
      await refreshSessions()
      return info
    } catch {
      return null
    }
  }, [refreshSessions])

  const handleModelPick = useCallback(async (modelId: string) => {
    setShowModelPicker(false)
    setShowSessionDrawer(false)
    if (modelId === CLAUDE_CODE_MODEL_ID) {
      await refreshSessions()
      const discovered = await window.electronAPI.getClaudeCodeSessions().catch(() => [])
      setClaudeCodeSessions(discovered || [])
      setShowClaudeCodeSessionPicker(true)
      setShowCodexSessionPicker(false)
      return
    }
    if (modelId === CODEX_MODEL_ID) {
      await refreshSessions()
      const discovered = await window.electronAPI.getCodexSessions().catch(() => [])
      setCodexSessions(discovered || [])
      setShowCodexSessionPicker(true)
      setShowClaudeCodeSessionPicker(false)
      return
    }
    setShowClaudeCodeSessionPicker(false)
    setShowCodexSessionPicker(false)
    await handleNewChat(modelId)
  }, [handleNewChat, refreshSessions])

  const handlePickClaudeCodeSession = useCallback(async (conversationId: string, cwd?: string) => {
    setShowClaudeCodeSessionPicker(false)
    setShowCodexSessionPicker(false)
    setShowSessionDrawer(false)
    await handleNewChat(CLAUDE_CODE_MODEL_ID, {
      claude_code_conversation_id: conversationId,
      ...(cwd ? { claude_code_cwd: cwd } : {})
    })
  }, [handleNewChat])

  const handlePickCodexSession = useCallback(async (conversationId: string, cwd?: string) => {
    setShowCodexSessionPicker(false)
    setShowClaudeCodeSessionPicker(false)
    setShowSessionDrawer(false)
    await handleNewChat(CODEX_MODEL_ID, {
      codex_conversation_id: conversationId,
      ...(cwd ? { codex_cwd: cwd } : {})
    })
  }, [handleNewChat])

  const handlePickSession = useCallback(async (session: SessionInfo) => {
    setShowSessionDrawer(false)
    await handleSelectSession(session)
  }, [handleSelectSession])

  const handleDeleteSession = useCallback(async (e: React.MouseEvent, sessionId: string) => {
    e.stopPropagation()
    try {
      await window.electronAPI.deleteSession(sessionId)
      if (currentSession?.id === sessionId) {
        setCurrentSession(null)
        setChatMessages([])
      }
      await refreshSessions()
    } catch {
      // non-fatal
    }
  }, [currentSession, refreshSessions])

  const clearSessionToggleDrag = useCallback(() => {
    const drag = sessionToggleDragRef.current
    if (!drag) return
    window.removeEventListener("mousemove", drag.moveHandler)
    window.removeEventListener("mouseup", drag.upHandler)
    sessionToggleDragRef.current = null
  }, [])

  const startWindowDragOrAction = useCallback((
    event: React.MouseEvent<HTMLElement>,
    onClickWithoutDrag: () => void
  ) => {
    if (event.button !== 0) return
    event.preventDefault()

    const drag = {
      moved: false,
      startX: event.screenX,
      startY: event.screenY,
      lastX: event.screenX,
      lastY: event.screenY,
      moveHandler: (_moveEvent: MouseEvent) => {},
      upHandler: () => {}
    }

    drag.moveHandler = (moveEvent: MouseEvent) => {
      const active = sessionToggleDragRef.current
      if (!active) return

      const dx = moveEvent.screenX - active.lastX
      const dy = moveEvent.screenY - active.lastY
      if (dx === 0 && dy === 0) return

      active.lastX = moveEvent.screenX
      active.lastY = moveEvent.screenY

      const movedDistance = Math.abs(moveEvent.screenX - active.startX) + Math.abs(moveEvent.screenY - active.startY)
      if (movedDistance >= 2) {
        active.moved = true
      }

      if (active.moved) {
        window.electronAPI.moveWindowBy(dx, dy).catch(() => {})
      }
    }

    drag.upHandler = () => {
      const active = sessionToggleDragRef.current
      clearSessionToggleDrag()
      if (!active?.moved) {
        onClickWithoutDrag()
      }
    }

    clearSessionToggleDrag()
    sessionToggleDragRef.current = drag
    window.addEventListener("mousemove", drag.moveHandler)
    window.addEventListener("mouseup", drag.upHandler, { once: true })
  }, [clearSessionToggleDrag])

  const handleSessionToggleMouseDown = useCallback((event: React.MouseEvent<HTMLButtonElement>) => {
    startWindowDragOrAction(event, () => setShowSessionDrawer((v) => !v))
  }, [startWindowDragOrAction])

  const handleToggleWindowMouseDown = useCallback((event: React.MouseEvent<HTMLButtonElement>) => {
    startWindowDragOrAction(event, () => {
      void window.electronAPI.toggleWindow()
    })
  }, [startWindowDragOrAction])

  const handleShowModelPickerMouseDown = useCallback((event: React.MouseEvent<HTMLButtonElement>) => {
    startWindowDragOrAction(event, () => setShowModelPicker(true))
  }, [startWindowDragOrAction])

  const handleCollapseMouseDown = useCallback((event: React.MouseEvent<HTMLButtonElement>) => {
    startWindowDragOrAction(event, () => setIsExpanded(false))
  }, [startWindowDragOrAction])

  const handleCollapsedTitleMouseDown = useCallback((event: React.MouseEvent<HTMLSpanElement>) => {
    startWindowDragOrAction(event, () => setIsExpanded(true))
  }, [startWindowDragOrAction])

  const handleCollapsedExpandMouseDown = useCallback((event: React.MouseEvent<HTMLButtonElement>) => {
    startWindowDragOrAction(event, () => setIsExpanded(true))
  }, [startWindowDragOrAction])

  const handleToggleWindowKeyDown = useCallback((event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      void window.electronAPI.toggleWindow()
    }
  }, [])

  const handleShowModelPickerKeyDown = useCallback((event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      setShowModelPicker(true)
    }
  }, [])

  const handleCollapseKeyDown = useCallback((event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      setIsExpanded(false)
    }
  }, [])

  const handleCollapsedExpandKeyDown = useCallback((event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      setIsExpanded(true)
    }
  }, [])

  const handleSessionToggleKeyDown = useCallback((event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      setShowSessionDrawer((v) => !v)
    }
  }, [])

  const sortedSessions = useMemo(() => {
    return [...sessions].sort((a, b) => {
      const ta = (a as any).updated_at || (a as any).created_at || ""
      const tb = (b as any).updated_at || (b as any).created_at || ""
      return tb.localeCompare(ta)
    })
  }, [sessions])

  const claudeCodeLinkChoices = useMemo(() => {
    const byId = new Map<string, { conversationId: string; sessionName: string; cwd?: string; updatedAt: string }>()
    for (const s of sessions) {
      const conversationId = (
        s.metadata?.claude_code_conversation_id ||
        (s.model === CLAUDE_CODE_MODEL_ID ? s.id : "")
      ).trim()
      if (!conversationId || byId.has(conversationId)) continue
      byId.set(conversationId, {
        conversationId,
        sessionName: s.name || "Untitled",
        cwd: s.metadata?.claude_code_cwd,
        updatedAt: (s as any).updated_at || (s as any).created_at || ""
      })
    }

    for (const discovered of claudeCodeSessions) {
      const conversationId = (discovered.id || "").trim()
      if (!conversationId || byId.has(conversationId)) continue
      byId.set(conversationId, {
        conversationId,
        sessionName: discovered.title || "Claude Code Session",
        cwd: discovered.cwd,
        updatedAt: discovered.timestamp || ""
      })
    }

    const choices = [...byId.values()]
    choices.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    return choices
  }, [sessions, claudeCodeSessions])

  const codexLinkChoices = useMemo(() => {
    const byId = new Map<string, { conversationId: string; sessionName: string; cwd?: string; updatedAt: string }>()
    for (const s of sessions) {
      const conversationId = (
        s.metadata?.codex_conversation_id ||
        (s.model === CODEX_MODEL_ID ? s.id : "")
      ).trim()
      if (!conversationId || byId.has(conversationId)) continue
      byId.set(conversationId, {
        conversationId,
        sessionName: s.name || "Untitled",
        cwd: s.metadata?.codex_cwd,
        updatedAt: (s as any).updated_at || (s as any).created_at || ""
      })
    }

    for (const discovered of codexSessions) {
      const conversationId = (discovered.id || "").trim()
      if (!conversationId || byId.has(conversationId)) continue
      byId.set(conversationId, {
        conversationId,
        sessionName: discovered.title || "Codex Session",
        cwd: discovered.cwd,
        updatedAt: discovered.timestamp || ""
      })
    }

    const choices = [...byId.values()]
    choices.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    return choices
  }, [sessions, codexSessions])

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
      backendPath: backendPath.trim() || "/v1/agent",
      model: selectedSession?.model || "gpt-5.2",
      workspaceId: selectedSession?.id || workspaceId,
      sessionId: selectedSession?.id || sessionId,
      claudeCodeConversationId: selectedSession?.metadata?.claude_code_conversation_id || "",
      codexConversationId: selectedSession?.metadata?.codex_conversation_id || "",
      authToken: backendAuthToken
    }

    try {
      const isCodexSession = selectedSession.model === CODEX_MODEL_ID
      const isClaudeCodeSession = selectedSession.model === CLAUDE_CODE_MODEL_ID
      if (isCodexSession || isClaudeCodeSession) {
        await window.electronAPI.createSessionMessage({
          sessionId: selectedSession.id,
          role: "user",
          content: trimmed
        }).catch(() => {})

        let cleanText = ""
        if (isCodexSession) {
          const codexConversationId = (selectedSession?.metadata?.codex_conversation_id || "").trim()
          const codexCwd = selectedSession?.metadata?.codex_cwd?.trim() || undefined
          if (!codexConversationId) {
            throw new Error("Codex conversation id is missing for this session")
          }
          const result = await window.electronAPI.sendCodexMessage({
            conversationId: codexConversationId,
            prompt: trimmed,
            cwd: codexCwd
          })
          cleanText = result?.text || ""
        } else {
          const claudeCodeConversationId = (selectedSession?.metadata?.claude_code_conversation_id || "").trim()
          const claudeCodeCwd = selectedSession?.metadata?.claude_code_cwd?.trim() || undefined
          if (!claudeCodeConversationId) {
            throw new Error("Claude Code conversation id is missing for this session")
          }
          const result = await window.electronAPI.sendClaudeCodeMessage({
            conversationId: claudeCodeConversationId,
            prompt: trimmed,
            cwd: claudeCodeCwd
          })
          cleanText = result?.text || ""
        }

        if (cleanText) {
          await applyFinalAssistantOutput(cleanText, (clean) => setAssistantText(clean))
        } else {
          setAssistantText(isCodexSession ? "Codex returned no text." : "Claude Code returned no text.")
        }

        const assistantText = cleanText || (isCodexSession ? "Codex returned no text." : "Claude Code returned no text.")
        await window.electronAPI.createSessionMessage({
          sessionId: selectedSession.id,
          role: "assistant",
          content: assistantText
        }).catch(() => {})
      } else {
        if (!settings.backendBaseUrl) {
          throw new Error("Backend URL is required")
        }

        await requestAgentResponse({
          settings,
          requestId,
          message: trimmed,
          history: chatMessages,
          callbacks: {
            onFinal: (text) => {
              if (activeStreamRequestRef.current !== requestId) return
              if (text) {
                void applyFinalAssistantOutput(text, (clean) => setAssistantText(clean))
              }
            },
            onStatus: () => {},
            onToolCall: (name, input) => {
              if (activeStreamRequestRef.current !== requestId) return
              const tc = input as ToolCallInfo | undefined
              setChatMessages((msgs) => {
                if (msgs.length === 0) return msgs
                const updated = [...msgs]
                const idx = updated.length - 1
                const prev = updated[idx]
                const existing = prev.toolCalls || []
                updated[idx] = { ...prev, toolCalls: [...existing, { name, ...tc }] }
                return updated
              })
            },
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
      }
    } catch (error: any) {
      setAssistantText(`Error: ${error?.message || String(error)}`)
    } finally {
      activeStreamRequestRef.current = null
      setChatLoading(false)

      // Reload from server so all messages have _ids (prevents poller duplication)
      try {
        const data = await window.electronAPI.getSessionMessages(selectedSession.id)
        const msgs = (data?.items || []).map((m: any) => ({
          role: m.role as "user" | "assistant",
          text: m.content,
          _id: m.id
        }))
        if (msgs.length > 0) setChatMessages(msgs)
      } catch {
        // keep local state
      }

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

  // Load messages when auto-selected session changes and chat is empty
  useEffect(() => {
    if (!currentSession || chatMessages.length > 0) return
    let cancelled = false
    ;(async () => {
      try {
        const data = await window.electronAPI.getSessionMessages(currentSession.id)
        if (cancelled) return
        const msgs = (data?.items || []).map((m: any) => ({
          role: m.role as "user" | "assistant",
          text: m.content,
          _id: m.id
        }))
        if (msgs.length > 0) setChatMessages(msgs)
      } catch {
        // non-fatal
      }
    })()
    return () => { cancelled = true }
  }, [currentSession?.id])  // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const cleanup = window.electronAPI.onSessionMessagesUpdate((data: { sessionId: string; messages: any[] }) => {
      if (!currentSession || data.sessionId !== currentSession.id) return

      const incoming = (data.messages || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id,
        ...(m.tool_calls?.length ? { toolCalls: m.tool_calls } : {})
      }))

      if (incoming.length === 0) return

      setChatMessages((prev) => {
        const updated = [...prev]
        const existingById = new Map<string, number>()
        updated.forEach((m, i) => {
          if (m._id) existingById.set(m._id, i)
        })

        for (const msg of incoming) {
          if (msg._id && existingById.has(msg._id)) {
            continue
          }

          if (msg._id) {
            // Reconcile optimistic local echoes (no _id) with canonical server messages.
            const optimisticIdx = updated.findIndex(
              (m) => !m._id && m.role === msg.role && m.text === msg.text
            )
            if (optimisticIdx >= 0) {
              updated[optimisticIdx] = { ...updated[optimisticIdx], ...msg }
              existingById.set(msg._id, optimisticIdx)
              continue
            }
          }

          updated.push(msg)
          if (msg._id) {
            existingById.set(msg._id, updated.length - 1)
          }
        }

        return updated
      })
    })

    return cleanup
  }, [currentSession])

  useEffect(() => {
    if (!messageListRef.current) return
    messageListRef.current.scrollTop = messageListRef.current.scrollHeight
  }, [chatMessages, chatLoading])

  useEffect(() => {
    return () => clearSessionToggleDrag()
  }, [clearSessionToggleDrag])

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

      {showModelPicker && (
        <div className="iris-agent-picker-backdrop interactive" onClick={() => setShowModelPicker(false)}>
          <div className="iris-agent-picker" onClick={(e) => e.stopPropagation()}>
            <div className="iris-agent-picker-title">New Chat</div>
            {modelChoices.map((choice) => (
              <button
                key={choice.id}
                type="button"
                className="iris-agent-picker-option interactive"
                onClick={() => handleModelPick(choice.id)}
              >
                <span className="iris-agent-picker-name">{choice.name}</span>
                <span className="iris-agent-picker-sub">{choice.subtitle}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {showClaudeCodeSessionPicker && (
        <div
          className="iris-agent-picker-backdrop interactive"
          onClick={() => setShowClaudeCodeSessionPicker(false)}
        >
          <div className="iris-agent-picker" onClick={(e) => e.stopPropagation()}>
            <div className="iris-agent-picker-title">Link Claude Code Session</div>
            {claudeCodeLinkChoices.length === 0 ? (
              <div className="iris-session-empty">No linked Claude Code sessions found yet.</div>
            ) : (
              claudeCodeLinkChoices.map((choice) => (
                <button
                  key={choice.conversationId}
                  type="button"
                  className="iris-agent-picker-option interactive"
                  onClick={() => handlePickClaudeCodeSession(choice.conversationId, choice.cwd)}
                >
                  <span className="iris-agent-picker-name">{choice.sessionName}</span>
                  <span className="iris-agent-picker-sub">{choice.conversationId.slice(0, 8)}</span>
                </button>
              ))
            )}
          </div>
        </div>
      )}

      {showCodexSessionPicker && (
        <div
          className="iris-agent-picker-backdrop interactive"
          onClick={() => setShowCodexSessionPicker(false)}
        >
          <div className="iris-agent-picker" onClick={(e) => e.stopPropagation()}>
            <div className="iris-agent-picker-title">Link Codex Session</div>
            {codexLinkChoices.length === 0 ? (
              <div className="iris-session-empty">No linked Codex sessions found yet.</div>
            ) : (
              codexLinkChoices.map((choice) => (
                <button
                  key={choice.conversationId}
                  type="button"
                  className="iris-agent-picker-option interactive"
                  onClick={() => handlePickCodexSession(choice.conversationId, choice.cwd)}
                >
                  <span className="iris-agent-picker-name">{choice.sessionName}</span>
                  <span className="iris-agent-picker-sub">{choice.conversationId.slice(0, 8)}</span>
                </button>
              ))
            )}
          </div>
        </div>
      )}

      {!isExpanded ? (
        /* Collapsed: compact bar with convo name and close */
        <div className="iris-floating-bar draggable-area">
          <button
            type="button"
            className="iris-toggle interactive"
            onMouseDown={handleToggleWindowMouseDown}
            onKeyDown={handleToggleWindowKeyDown}
            aria-label="Close"
          >
            <X size={13} />
          </button>
          <span className="iris-bar-title interactive" onMouseDown={handleCollapsedTitleMouseDown}>
            {currentSession?.name || "Iris"}
          </span>
          <button
            type="button"
            className="iris-toggle interactive"
            onMouseDown={handleCollapsedExpandMouseDown}
            onKeyDown={handleCollapsedExpandKeyDown}
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
              onMouseDown={handleShowModelPickerMouseDown}
              onKeyDown={handleShowModelPickerKeyDown}
              title="New chat"
            >
              <Plus size={11} />
            </button>
            <button
              type="button"
              className={`iris-session-toggle interactive ${showSessionDrawer ? "active" : ""}`}
              onMouseDown={handleSessionToggleMouseDown}
              onKeyDown={handleSessionToggleKeyDown}
              title="Browse sessions"
              aria-label="Browse sessions"
            >
              <MessageSquare size={10} />
              <span className="iris-session-toggle-label">
                {currentSession?.name || "Iris"}
              </span>
              <ChevronDown
                size={9}
                className={`iris-session-chevron ${showSessionDrawer ? "open" : ""}`}
              />
            </button>
            <button
              type="button"
              className="iris-toggle interactive"
              onMouseDown={handleCollapseMouseDown}
              onKeyDown={handleCollapseKeyDown}
              aria-label="Collapse"
            >
              <ChevronUp size={13} />
            </button>
          </header>

          {showSessionDrawer && (
            <div className="iris-session-drawer interactive">
              <div className="iris-session-list">
                {sortedSessions.length === 0 ? (
                  <div className="iris-session-empty">No sessions yet</div>
                ) : (
                  sortedSessions.map((s) => {
                    const isActive = currentSession?.id === s.id
                    const ts = (s as any).updated_at || (s as any).created_at || ""
                    const modelLabel = s.model === CLAUDE_CODE_MODEL_ID
                      ? "Claude Code"
                      : s.model === CODEX_MODEL_ID
                        ? "Codex"
                      : s.model?.includes("claude")
                        ? "Claude"
                      : s.model?.includes("gemini")
                        ? "Gemini"
                        : s.model === "gpt-5.2"
                          ? "GPT-5.2"
                          : s.model || "GPT-5.2"
                    return (
                      <button
                        key={s.id}
                        type="button"
                        className={`iris-session-row ${isActive ? "active" : ""}`}
                        onClick={() => handlePickSession(s)}
                      >
                        <div className="iris-session-row-main">
                          <span className="iris-session-row-name">{s.name || "Untitled"}</span>
                          <span className="iris-session-row-model">{modelLabel}</span>
                        </div>
                        {ts && (
                          <span className="iris-session-row-time">
                            {formatRelativeTime(ts)}
                          </span>
                        )}
                        <button
                          type="button"
                          className="iris-session-row-delete"
                          onClick={(e) => handleDeleteSession(e, s.id)}
                          aria-label="Delete session"
                        >
                          <X size={10} />
                        </button>
                      </button>
                    )
                  })
                )}
              </div>
            </div>
          )}

          <main className="iris-chat">
            <div ref={messageListRef} className="iris-messages interactive">
              {chatMessages.length === 0 ? (
                <div className="iris-empty">Start a conversation</div>
              ) : (
                chatMessages.map((msg, idx) => (
                  <div key={idx} className={`iris-msg ${msg.role}`}>
                    <div className="iris-msg-bubble">
                      {msg.role === "assistant" && msg.toolCalls?.length ? (
                        <div className="iris-tool-calls">
                          {msg.toolCalls.map((tc, i) => (
                            <span key={i} className="iris-tool-chip">
                              <span className="iris-tool-chip-name">{tc.name}</span>
                              {tc.target && <span className="iris-tool-chip-target">{tc.target}</span>}
                            </span>
                          ))}
                        </div>
                      ) : null}
                      {msg.role === "assistant" ? (
                        msg.text ? (
                          <ReactMarkdown
                            className="iris-markdown"
                            remarkPlugins={[remarkGfm, remarkMath]}
                            rehypePlugins={[rehypeKatex]}
                          >
                            {msg.text}
                          </ReactMarkdown>
                        ) : msg.toolCalls?.length ? null : (
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

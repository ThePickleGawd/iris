import React, { useEffect, useMemo, useRef, useState, useCallback } from "react"
import { useQuery } from "react-query"
import { X, Mic, SendHorizontal, ListTodo, ImagePlus, Wifi, Monitor, Tablet, Plus } from "lucide-react"
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
import ScreenshotQueue from "../components/Queue/ScreenshotQueue"
import { createRequestId } from "../lib/agentProtocol"
import type { AgentTransportSettings } from "../lib/agentProtocol"
import { streamAgentResponse } from "../lib/agentTransport"
import { extractWidgetBlocks, normalizeWidgetSpec } from "../lib/widgetProtocol"

let localTranscriberPromise: Promise<any> | null = null

async function getLocalTranscriber() {
  if (!localTranscriberPromise) {
    localTranscriberPromise = (async () => {
      const { pipeline, env } = await import(
        /* @vite-ignore */ "https://cdn.jsdelivr.net/npm/@xenova/transformers@2.17.2"
      )
      env.allowLocalModels = false
      env.useBrowserCache = true
      return pipeline("automatic-speech-recognition", "Xenova/whisper-tiny.en")
    })()
  }
  return localTranscriberPromise
}

function mixToMono(buffer: AudioBuffer): Float32Array {
  const channels = buffer.numberOfChannels
  const length = buffer.length
  if (channels === 1) return buffer.getChannelData(0).slice()

  const mono = new Float32Array(length)
  for (let ch = 0; ch < channels; ch++) {
    const data = buffer.getChannelData(ch)
    for (let i = 0; i < length; i++) {
      mono[i] += data[i]
    }
  }
  for (let i = 0; i < length; i++) {
    mono[i] /= channels
  }
  return mono
}

function resampleTo16k(input: Float32Array, inputRate: number): Float32Array {
  if (inputRate === 16000) return input
  const ratio = inputRate / 16000
  const outLength = Math.max(1, Math.floor(input.length / ratio))
  const output = new Float32Array(outLength)
  for (let i = 0; i < outLength; i++) {
    const pos = i * ratio
    const left = Math.floor(pos)
    const right = Math.min(left + 1, input.length - 1)
    const frac = pos - left
    output[i] = input[left] * (1 - frac) + input[right] * frac
  }
  return output
}

function playReplyPing() {
  try {
    const Ctx = (window as any).AudioContext || (window as any).webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()
    osc.type = "sine"
    osc.frequency.setValueAtTime(880, ctx.currentTime)
    gain.gain.setValueAtTime(0.0001, ctx.currentTime)
    gain.gain.exponentialRampToValueAtTime(0.08, ctx.currentTime + 0.01)
    gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.20)
    osc.connect(gain)
    gain.connect(ctx.destination)
    osc.start()
    osc.stop(ctx.currentTime + 0.22)
    setTimeout(() => {
      ctx.close().catch(() => {})
    }, 300)
  } catch {
    // Ignore audio ping errors.
  }
}

interface PendingImage {
  name: string
  mimeType: string
  base64Data: string
  dataUrl: string
}

interface DiagramWidget {
  id: string
  title: string
  from: string
  to: string
  note: string
}

const Queue: React.FC = () => {
  const [toastOpen, setToastOpen] = useState(false)
  const [toastMessage, setToastMessage] = useState<ToastMessage>({
    title: "",
    description: "",
    variant: "neutral"
  })
  const [isExpanded, setIsExpanded] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [diagramWidgets, setDiagramWidgets] = useState<DiagramWidget[]>([])

  const [chatInput, setChatInput] = useState("")
  const [chatMessages, setChatMessages] = useState<{ role: "user" | "assistant"; text: string }[]>([])
  const [chatLoading, setChatLoading] = useState(false)
  const [isVoiceRecording, setIsVoiceRecording] = useState(false)
  const [isVoiceTranscribing, setIsVoiceTranscribing] = useState(false)
  const [notificationsEnabled, setNotificationsEnabled] = useState(true)
  const [soundPingEnabled, setSoundPingEnabled] = useState(true)
  const [backendBaseUrl, setBackendBaseUrl] = useState("http://localhost:8000")
  const [backendStreamPath, setBackendStreamPath] = useState("/v1/agent/stream")
  const [workspaceId, setWorkspaceId] = useState("default-workspace")
  const [sessionId, setSessionId] = useState("default-session")
  const [backendAuthToken, setBackendAuthToken] = useState("")
  const [pendingImage, setPendingImage] = useState<PendingImage | null>(null)
  const [macIp, setMacIp] = useState("")
  const [ipadIpInput, setIpadIpInput] = useState("")
  const [ipadPortInput, setIpadPortInput] = useState("8935")
  const [connectedDevices, setConnectedDevices] = useState<any[]>([])
  const [ipadConnecting, setIpadConnecting] = useState(false)
  const [ipadConnectError, setIpadConnectError] = useState("")
  const [sessions, setSessions] = useState<any[]>([])
  const [currentSession, setCurrentSession] = useState<{ id: string; agent: string; name: string } | null>(null)

  const contentRef = useRef<HTMLDivElement>(null)
  const chatInputRef = useRef<HTMLInputElement>(null)
  const messageListRef = useRef<HTMLDivElement>(null)
  const imageInputRef = useRef<HTMLInputElement>(null)

  const mediaRecorderRef = useRef<MediaRecorder | null>(null)
  const mediaStreamRef = useRef<MediaStream | null>(null)
  const mediaChunksRef = useRef<Blob[]>([])
  const activeStreamRequestRef = useRef<string | null>(null)

  const { data: screenshots = [], refetch } = useQuery<Array<{ path: string; preview: string }>, Error>(
    ["screenshots"],
    async () => {
      try {
        return await window.electronAPI.getScreenshots()
      } catch (error) {
        console.error("Error loading screenshots:", error)
        showToast("Error", "Failed to load screenshots", "error")
        return []
      }
    },
    {
      staleTime: Infinity,
      cacheTime: Infinity,
      refetchOnWindowFocus: true,
      refetchOnMount: true
    }
  )

  const showToast = (title: string, description: string, variant: ToastVariant) => {
    setToastMessage({ title, description, variant })
    setToastOpen(true)
  }

  const chatHint = useMemo(
    () => `Backend agent transport: ${backendBaseUrl}${backendStreamPath || "/v1/agent/stream"}`,
    [backendBaseUrl, backendStreamPath]
  )

  const handleAddDiagramWidget = useCallback(() => {
    setDiagramWidgets((prev) => [
      ...prev,
      {
        id: `diagram-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
        title: `Diagram ${prev.length + 1}`,
        from: "Input",
        to: "Output",
        note: ""
      }
    ])
    setIsExpanded(true)
  }, [])

  const handleUpdateDiagramWidget = useCallback(
    (id: string, field: keyof Omit<DiagramWidget, "id">, value: string) => {
      setDiagramWidgets((prev) =>
        prev.map((widget) => (widget.id === id ? { ...widget, [field]: value } : widget))
      )
    },
    []
  )

  const handleRemoveDiagramWidget = useCallback((id: string) => {
    setDiagramWidgets((prev) => prev.filter((widget) => widget.id !== id))
  }, [])

  const handleDeleteScreenshot = async (index: number) => {
    const screenshotToDelete = screenshots[index]
    if (!screenshotToDelete) return
    try {
      const result = await window.electronAPI.deleteScreenshot(screenshotToDelete.path)
      if (result.success) {
        await refetch()
      } else {
        showToast("Delete Failed", result.error || "Could not delete screenshot", "error")
      }
    } catch (error) {
      showToast("Delete Failed", "Could not delete screenshot", "error")
    }
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

  const sendChatMessage = async (message: string, image: PendingImage | null = null) => {
    const trimmed = message.trim()
    if (!trimmed && !image) return

    // Auto-create a session if none is selected
    if (!currentSession) {
      await handleNewChat()
    }

    const requestId = createRequestId()
    activeStreamRequestRef.current = requestId
    const userText = image ? `[Image] ${image.name}${trimmed ? `\n${trimmed}` : ""}` : trimmed
    setChatMessages((msgs) => [...msgs, { role: "user", text: userText }, { role: "assistant", text: "" }])
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
      workspaceId: currentSession?.id || workspaceId.trim(),
      sessionId: currentSession?.id || sessionId.trim(),
      authToken: backendAuthToken.trim()
    }

    try {
      if (image) {
        const response = await window.electronAPI.invoke(
          "analyze-image-base64",
          image.base64Data,
          image.mimeType,
          trimmed
        )
        const analysisText = String(response?.text || "").trim() || "No analysis text returned."

        const html = `
          <div class="img-wrap">
            <img src="${image.dataUrl}" alt="${image.name.replace(/"/g, "&quot;")}" />
          </div>
          <div class="analysis">
            <h3>Image Analysis</h3>
            <p>${analysisText.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "<br/>")}</p>
          </div>
        `

        await openWidget({
          id: `image-analysis-${Date.now()}`,
          title: `Image: ${image.name}`,
          kind: "html",
          width: 760,
          height: 620,
          css: `
            .img-wrap { margin-bottom: 12px; border:1px solid #e2e8f0; border-radius: 10px; overflow: hidden; background:#fff; }
            .img-wrap img { width: 100%; height: auto; max-height: 320px; object-fit: contain; display: block; background: #f8fafc; }
            .analysis h3 { margin: 0 0 8px 0; font-size: 14px; color:#0f172a; }
            .analysis p { margin: 0; font-size: 13px; line-height: 1.5; color:#334155; }
          `,
          payload: { html }
        })

        setAssistantText("Opened image analysis in a separate window.")
        return
      }

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
          onToolCall: (name) => {
            console.log(`[AgentTool] call: ${name}`)
          },
          onToolResult: (name) => {
            console.log(`[AgentTool] result: ${name}`)
          },
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
      if (image) setPendingImage(null)
      activeStreamRequestRef.current = null
      setChatLoading(false)
      chatInputRef.current?.focus()
    }
  }

  const handleChatSend = async () => {
    if (!chatInput.trim() && !pendingImage) return
    const message = chatInput
    setChatInput("")
    await sendChatMessage(message, pendingImage)
  }

  const handleGenerateTodoPopup = async () => {
    if (chatLoading) return

    const requestId = createRequestId()
    activeStreamRequestRef.current = requestId
    setChatLoading(true)
    setChatMessages((msgs) => [...msgs, { role: "assistant", text: "Generating TODO popup..." }])

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
      workspaceId: currentSession?.id || workspaceId.trim(),
      sessionId: currentSession?.id || sessionId.trim(),
      authToken: backendAuthToken.trim()
    }

    const transcript = chatMessages
      .slice(-80)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.text}`)
      .join("\n")

    const todoPrompt = `Create a polished TODO list from this Iris conversation transcript.

Output rules (strict):
- Return exactly ONE fenced block with language iris-widget.
- That block must contain valid JSON only.
- JSON must describe a popup widget with:
  - "kind": "html"
  - "title": "Iris TODO"
  - "width": 760
  - "height": 620
  - "css": modern minimalist style
  - "payload.html": structured TODO with sections: Done, Next, Later, Blocked / Needs Decision
- Use priorities (P0/P1/P2), owner/status/estimate.
- Do not output markdown outside the single iris-widget block.

Transcript:
${transcript || "No prior messages. Build a practical starter TODO for Iris Mac."}`

    try {
      await streamAgentResponse({
        settings,
        requestId,
        message: todoPrompt,
        history: chatMessages,
        callbacks: {
          onDelta: () => {},
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
            setAssistantText(`Error generating TODO popup: ${msg}`)
          }
        }
      })
    } catch (error: any) {
      setAssistantText(`Error generating TODO popup: ${error?.message || String(error)}`)
    } finally {
      activeStreamRequestRef.current = null
      setChatLoading(false)
      chatInputRef.current?.focus()
    }
  }

  const handleImagePickerClick = () => {
    if (chatLoading || isVoiceRecording || isVoiceTranscribing) return
    imageInputRef.current?.click()
  }

  const handleImageSelected = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    event.target.value = ""
    if (!file) return

    try {
      const dataUrl = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(String(reader.result || ""))
        reader.onerror = () => reject(new Error("Failed to read image file"))
        reader.readAsDataURL(file)
      })

      const match = dataUrl.match(/^data:([^;]+);base64,(.+)$/)
      if (!match) {
        throw new Error("Unsupported image encoding")
      }
      const mimeType = match[1]
      const base64Data = match[2]
      setPendingImage({
        name: file.name,
        mimeType,
        base64Data,
        dataUrl
      })
      if (!chatInput.trim()) {
        setChatInput("What should I do based on this image?")
      }
      showToast("Image Attached", "Add/edit your prompt, then press Send.", "neutral")
    } catch (error: any) {
      showToast("Image Upload Error", error?.message || "Failed to load image.", "error")
    }
    chatInputRef.current?.focus()
  }

  const transcribeBlobLocally = async (blob: Blob): Promise<string> => {
    const arrayBuffer = await blob.arrayBuffer()
    const audioContext = new AudioContext()
    const decoded = await audioContext.decodeAudioData(arrayBuffer.slice(0))
    const mono = mixToMono(decoded)
    const pcm16k = resampleTo16k(mono, decoded.sampleRate)
    await audioContext.close()

    const transcriber = await getLocalTranscriber()
    const output = await transcriber(pcm16k, {
      sampling_rate: 16000,
      chunk_length_s: 10,
      stride_length_s: 2,
      return_timestamps: false,
      generate_kwargs: {
        language: "english",
        task: "transcribe"
      }
    })

    const rawText = (typeof output === "string" ? output : output?.text || "").trim()
    return rawText.replace(/\[[A-Z ]+\]/g, "").trim()
  }

  const stopVoiceRecording = () => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== "inactive") {
      mediaRecorderRef.current.stop()
    }
  }

  const handleVoiceTranscription = async () => {
    if (chatLoading || isVoiceTranscribing) return

    if (isVoiceRecording) {
      stopVoiceRecording()
      return
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const recorder = new MediaRecorder(stream)
      mediaChunksRef.current = []
      mediaStreamRef.current = stream
      mediaRecorderRef.current = recorder

      recorder.ondataavailable = (event: BlobEvent) => {
        if (event.data && event.data.size > 0) {
          mediaChunksRef.current.push(event.data)
        }
      }

      recorder.onstop = async () => {
        setIsVoiceRecording(false)
        setIsVoiceTranscribing(true)
        try {
          const audioBlob = new Blob(mediaChunksRef.current, { type: "audio/webm" })
          const transcript = await transcribeBlobLocally(audioBlob)
          if (!transcript) {
            showToast("No Speech Detected", "Could not detect speech in recording.", "neutral")
          } else {
            setChatInput(transcript)
            showToast("Transcript Ready", "Review/edit transcript, then press Send.", "neutral")
          }
        } catch (error) {
          showToast("Voice Error", "Transcription failed. Please try again.", "error")
        } finally {
          setIsVoiceTranscribing(false)
          mediaChunksRef.current = []
          if (mediaStreamRef.current) {
            mediaStreamRef.current.getTracks().forEach((track) => track.stop())
            mediaStreamRef.current = null
          }
          mediaRecorderRef.current = null
        }
      }

      recorder.start()
      setIsVoiceRecording(true)
    } catch (error) {
      showToast("Voice Error", "Microphone access failed.", "error")
    }
  }

  // Load network info and connected devices
  useEffect(() => {
    const loadNetworkInfo = async () => {
      try {
        const info = await window.electronAPI.getNetworkInfo()
        setMacIp(info.macIp)
        setConnectedDevices(info.connectedDevices || [])
      } catch (error) {
        console.error("Error loading network info:", error)
      }
    }
    loadNetworkInfo()

    // Refresh on device events
    const cleanups = [
      window.electronAPI.onIrisDeviceFound(() => loadNetworkInfo()),
      window.electronAPI.onIrisDeviceLost(() => loadNetworkInfo()),
      window.electronAPI.onIrisDeviceUpdated(() => loadNetworkInfo()),
    ]
    return () => cleanups.forEach(c => c())
  }, [])

  // Load sessions and set up message sync
  const refreshSessions = useCallback(async () => {
    try {
      const data = await window.electronAPI.getSessions()
      setSessions(data?.items || [])
    } catch {
      // Session fetch failure is non-fatal
    }
  }, [])

  useEffect(() => {
    refreshSessions()
    const interval = setInterval(refreshSessions, 10_000)
    return () => clearInterval(interval)
  }, [refreshSessions])

  // Listen for polled session message updates from main process
  useEffect(() => {
    const cleanup = window.electronAPI.onSessionMessagesUpdate((data: { sessionId: string; messages: any[] }) => {
      if (!currentSession || data.sessionId !== currentSession.id) return
      const newMsgs = (data.messages || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id,
      }))
      if (newMsgs.length > 0) {
        setChatMessages((prev) => {
          const existingIds = new Set(prev.map((m: any) => m._id).filter(Boolean))
          const toAdd = newMsgs.filter((m: any) => !existingIds.has(m._id))
          return toAdd.length > 0 ? [...prev, ...toAdd] : prev
        })
      }
    })
    return cleanup
  }, [currentSession])

  const handleSelectSession = useCallback(async (session: any) => {
    const info = { id: session.id, agent: session.agent, name: session.name }
    setCurrentSession(info)
    setChatMessages([])
    setChatLoading(true)
    try {
      await window.electronAPI.setCurrentSession(info)
      const data = await window.electronAPI.getSessionMessages(session.id)
      const msgs = (data?.items || []).map((m: any) => ({
        role: m.role as "user" | "assistant",
        text: m.content,
        _id: m.id,
      }))
      setChatMessages(msgs)
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
      setCurrentSession({ id, agent, name })
      setChatMessages([])
      await refreshSessions()
    } catch {
      // Non-fatal
    }
  }, [refreshSessions])

  // Restore saved iPad IP
  useEffect(() => {
    try {
      const savedIp = localStorage.getItem("iris_ipad_ip")
      const savedPort = localStorage.getItem("iris_ipad_port")
      if (savedIp) setIpadIpInput(savedIp)
      if (savedPort) setIpadPortInput(savedPort)
    } catch {}
  }, [])

  const handleConnectIpad = useCallback(async () => {
    const ip = ipadIpInput.trim()
    if (!ip) return
    const port = parseInt(ipadPortInput, 10) || 8935
    setIpadConnecting(true)
    setIpadConnectError("")
    try {
      localStorage.setItem("iris_ipad_ip", ip)
      localStorage.setItem("iris_ipad_port", String(port))
      const result = await window.electronAPI.connectIpad(ip, port)
      if (result.success) {
        const info = await window.electronAPI.getNetworkInfo()
        setConnectedDevices(info.connectedDevices || [])
      } else {
        setIpadConnectError(result.error || "Connection failed")
      }
    } catch (err: any) {
      setIpadConnectError(err?.message || "Connection failed")
    } finally {
      setIpadConnecting(false)
    }
  }, [ipadIpInput, ipadPortInput])

  useEffect(() => {
    try {
      const savedNotifications = localStorage.getItem("iris_notifications_enabled")
      const savedSound = localStorage.getItem("iris_sound_ping_enabled")
      const savedBackendBaseUrl = localStorage.getItem("iris_backend_base_url")
      const savedBackendStreamPath = localStorage.getItem("iris_backend_stream_path")
      const savedWorkspaceId = localStorage.getItem("iris_workspace_id")
      const savedSessionId = localStorage.getItem("iris_session_id")
      const savedBackendAuthToken = localStorage.getItem("iris_backend_auth_token")
      if (savedNotifications !== null) {
        setNotificationsEnabled(savedNotifications === "true")
      }
      if (savedSound !== null) {
        setSoundPingEnabled(savedSound === "true")
      }
      if (savedBackendBaseUrl !== null) setBackendBaseUrl(savedBackendBaseUrl)
      if (savedBackendStreamPath !== null) setBackendStreamPath(savedBackendStreamPath)
      if (savedWorkspaceId !== null) setWorkspaceId(savedWorkspaceId)
      if (savedSessionId !== null) setSessionId(savedSessionId)
      if (savedBackendAuthToken !== null) setBackendAuthToken(savedBackendAuthToken)
    } catch {
      // ignore storage errors
    }
  }, [])

  useEffect(() => {
    try {
      localStorage.setItem("iris_notifications_enabled", String(notificationsEnabled))
    } catch {
      // ignore storage errors
    }
    window.electronAPI.setNotificationsEnabled(notificationsEnabled).catch(() => {})
  }, [notificationsEnabled])

  useEffect(() => {
    try {
      localStorage.setItem("iris_sound_ping_enabled", String(soundPingEnabled))
    } catch {
      // ignore storage errors
    }
  }, [soundPingEnabled])

  useEffect(() => {
    try {
      localStorage.setItem("iris_backend_base_url", backendBaseUrl)
      localStorage.setItem("iris_backend_stream_path", backendStreamPath)
      localStorage.setItem("iris_workspace_id", workspaceId)
      localStorage.setItem("iris_session_id", sessionId)
      localStorage.setItem("iris_backend_auth_token", backendAuthToken)
    } catch {
      // ignore storage errors
    }
  }, [backendBaseUrl, backendStreamPath, workspaceId, sessionId, backendAuthToken])

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

    const cleanupFunctions = [
      window.electronAPI.onScreenshotTaken(async (data) => {
        await refetch()
        setChatLoading(true)
        try {
          const latest = data?.path
          if (latest) {
            const response = await window.electronAPI.invoke("analyze-image-file", latest)
            setChatMessages((msgs) => [...msgs, { role: "assistant", text: response.text }])
            setIsExpanded(true)
          }
        } catch (err) {
          setChatMessages((msgs) => [...msgs, { role: "assistant", text: "Error: " + String(err) }])
        } finally {
          setChatLoading(false)
        }
      }),
      window.electronAPI.onResetView(() => refetch()),
      window.electronAPI.onProcessingNoScreenshots(() => {
        showToast("No Screenshots", "There are no screenshots to process.", "neutral")
      }),
      window.electronAPI.onAgentReply(() => {
        if (soundPingEnabled) {
          playReplyPing()
        }
      })
    ]

    return () => {
      resizeObserver.disconnect()
      cleanupFunctions.forEach((cleanup) => cleanup())
    }
  }, [refetch, soundPingEnabled])

  useEffect(() => {
    return () => {
      if (mediaRecorderRef.current && mediaRecorderRef.current.state !== "inactive") {
        mediaRecorderRef.current.stop()
      }
      if (mediaStreamRef.current) {
        mediaStreamRef.current.getTracks().forEach((track) => track.stop())
        mediaStreamRef.current = null
      }
      activeStreamRequestRef.current = null
    }
  }, [])

  return (
    <div ref={contentRef} className="assistant-surface select-none">
      <Toast open={toastOpen} onOpenChange={setToastOpen} variant={toastMessage.variant} duration={3000}>
        <ToastTitle>{toastMessage.title}</ToastTitle>
        <ToastDescription>{toastMessage.description}</ToastDescription>
      </Toast>

      <div className={`compact-shell liquid-glass ${isExpanded ? "shell-expanded" : "shell-collapsed"}`}>
        <header className="compact-header draggable-area">
          <div className="header-row interactive">
            <div className="brand-chip">Iris</div>
            <div className="header-meta">{currentSession ? currentSession.agent : "No active chat"}</div>
            <button
              type="button"
              className="header-quit"
              onClick={() => window.electronAPI.quitApp()}
              title="Exit"
            >
              <X size={14} />
            </button>
          </div>
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
              title="New chat session"
            >
              <Plus size={12} />
              New
            </button>
          </div>
          <button
            type="button"
            className="expand-toggle interactive"
            onClick={() => setIsExpanded((value) => !value)}
          >
            {isExpanded ? "Collapse chat" : "Expand chat"}
          </button>
        </header>

        {isExpanded ? (
          <div className={`workspace-grid ${diagramWidgets.length > 0 ? "workspace-grid-widgets" : ""}`}>
            <section className="chat-panel">
              <div className="chat-toolbar">
                <div className="chat-hint">{chatHint}</div>
                <div className="chat-toolbar-actions">
                  <button
                    type="button"
                    className="toolbar-btn"
                    onClick={() => setShowSettings((value) => !value)}
                  >
                    {showSettings ? "Hide Settings" : "Settings"}
                  </button>
                  <button
                    type="button"
                    className="toolbar-btn"
                    onClick={handleAddDiagramWidget}
                  >
                    Diagram
                  </button>
                  <button
                    type="button"
                    className="toolbar-btn"
                    onClick={handleGenerateTodoPopup}
                    disabled={chatLoading || isVoiceRecording || isVoiceTranscribing}
                    title="Generate TODO popup from conversation"
                  >
                    <ListTodo size={12} />
                    TODO
                  </button>
                </div>
              </div>

              {screenshots.length > 0 && (
                <ScreenshotQueue
                  isLoading={chatLoading}
                  screenshots={screenshots}
                  onDeleteScreenshot={handleDeleteScreenshot}
                />
              )}

              <div ref={messageListRef} className="chat-log">
                {chatMessages.length === 0 ? (
                  <div className="chat-empty">
                    Start chatting, or use mic/image to draft input and press Send.
                  </div>
                ) : (
                  chatMessages.map((msg, idx) => (
                    <div
                      key={idx}
                      className={`chat-row ${msg.role === "user" ? "chat-row-user" : "chat-row-assistant"}`}
                    >
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
                  ref={imageInputRef}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={handleImageSelected}
                />
                <input
                  ref={chatInputRef}
                  className="chat-input"
                  placeholder={pendingImage ? `Image attached: ${pendingImage.name}` : "Type a message..."}
                  value={chatInput}
                  onChange={(e) => setChatInput(e.target.value)}
                  disabled={chatLoading || isVoiceRecording || isVoiceTranscribing}
                />
                {pendingImage && (
                  <button
                    type="button"
                    className="toolbar-btn toolbar-btn-subtle"
                    onClick={() => setPendingImage(null)}
                    title="Remove attached image"
                  >
                    Remove
                  </button>
                )}
                <button
                  type="button"
                  className="chat-icon-btn"
                  onClick={handleImagePickerClick}
                  disabled={chatLoading || isVoiceRecording || isVoiceTranscribing}
                  aria-label="Upload image"
                  title="Upload image"
                >
                  <ImagePlus size={16} />
                </button>
                <button
                  type="button"
                  className={`chat-icon-btn ${isVoiceRecording ? "chat-mic-recording" : ""}`}
                  onClick={handleVoiceTranscription}
                  disabled={chatLoading || isVoiceTranscribing}
                  aria-label={isVoiceRecording ? "Stop voice recording" : "Start voice recording"}
                  title={isVoiceRecording ? "Stop recording" : "Record and transcribe"}
                >
                  <Mic size={16} />
                </button>
                <button
                  type="submit"
                  className="chat-send"
                  disabled={chatLoading || isVoiceRecording || isVoiceTranscribing || (!chatInput.trim() && !pendingImage)}
                  aria-label="Send"
                >
                  <SendHorizontal size={16} />
                </button>
              </form>

              {showSettings && (
                <div className="settings-sheet">
                  <div className="config-card">
                    <div className="config-label">Agent Transport</div>
                    <div className="config-grid">
                      <label className="field-label">
                        Backend URL
                        <input
                          className="field-input"
                          value={backendBaseUrl}
                          onChange={(e) => setBackendBaseUrl(e.target.value)}
                          placeholder="http://localhost:8000"
                        />
                      </label>
                      <label className="field-label">
                        Stream Path
                        <input
                          className="field-input"
                          value={backendStreamPath}
                          onChange={(e) => setBackendStreamPath(e.target.value)}
                          placeholder="/v1/agent/stream"
                        />
                      </label>
                      <label className="field-label">
                        Workspace ID
                        <input
                          className="field-input"
                          value={workspaceId}
                          onChange={(e) => setWorkspaceId(e.target.value)}
                          placeholder="default-workspace"
                        />
                      </label>
                      <label className="field-label">
                        Session ID
                        <input
                          className="field-input"
                          value={sessionId}
                          onChange={(e) => setSessionId(e.target.value)}
                          placeholder="default-session"
                        />
                      </label>
                      <label className="field-label">
                        Backend Auth Token
                        <input
                          type="password"
                          className="field-input"
                          value={backendAuthToken}
                          onChange={(e) => setBackendAuthToken(e.target.value)}
                          placeholder="Bearer token"
                        />
                      </label>
                    </div>
                  </div>
                  <div className="config-card">
                    <label className="toggle-row">
                      <span>Desktop notifications</span>
                      <button
                        type="button"
                        onClick={() => setNotificationsEnabled((v) => !v)}
                        className={`toggle ${notificationsEnabled ? "toggle-on" : ""}`}
                        aria-pressed={notificationsEnabled}
                      >
                        <span className="toggle-knob" />
                      </button>
                    </label>
                    <label className="toggle-row">
                      <span>Sound ping on reply</span>
                      <button
                        type="button"
                        onClick={() => setSoundPingEnabled((v) => !v)}
                        className={`toggle ${soundPingEnabled ? "toggle-on" : ""}`}
                        aria-pressed={soundPingEnabled}
                      >
                        <span className="toggle-knob" />
                      </button>
                    </label>
                  </div>
                  <div className="config-card">
                    <div className="config-label config-label-inline">
                      <Wifi size={14} />
                      <span>Devices</span>
                    </div>
                    <div className="device-line">
                      <Monitor size={12} />
                      <span>This Mac:</span>
                      <code className="device-code">{macIp || "..."}</code>
                    </div>
                    {connectedDevices.length > 0 && (
                      <div className="device-list">
                        {connectedDevices.map((d: any) => (
                          <div key={d.id} className="device-chip">
                            <Tablet size={12} />
                            <span>{d.name}</span>
                            <code className="device-chip-code">
                              {d.host}:{d.port}
                            </code>
                            {d.linked && <span className="device-chip-state">linked</span>}
                          </div>
                        ))}
                      </div>
                    )}
                    <div className="device-connect">
                      <input
                        className="field-input font-mono"
                        value={ipadIpInput}
                        onChange={(e) => setIpadIpInput(e.target.value)}
                        placeholder="192.168.x.x"
                      />
                      <input
                        className="field-input field-input-port font-mono"
                        value={ipadPortInput}
                        onChange={(e) => setIpadPortInput(e.target.value)}
                        placeholder="8935"
                      />
                      <button
                        type="button"
                        className="toolbar-btn toolbar-btn-primary"
                        onClick={handleConnectIpad}
                        disabled={ipadConnecting || !ipadIpInput.trim()}
                      >
                        {ipadConnecting ? "..." : "Connect"}
                      </button>
                    </div>
                    {ipadConnectError && <div className="field-error">{ipadConnectError}</div>}
                  </div>
                </div>
              )}
            </section>

            {diagramWidgets.length > 0 && (
              <aside className="widget-rail">
                {diagramWidgets.map((widget) => {
                  const arrowId = `${widget.id}-arrow`
                  return (
                    <article key={widget.id} className="widget-card">
                      <div className="widget-card-header">
                        <input
                          className="widget-title"
                          value={widget.title}
                          onChange={(e) => handleUpdateDiagramWidget(widget.id, "title", e.target.value)}
                        />
                        <button
                          type="button"
                          className="widget-remove"
                          onClick={() => handleRemoveDiagramWidget(widget.id)}
                        >
                          <X size={12} />
                        </button>
                      </div>
                      <svg className="diagram-preview" viewBox="0 0 320 120" role="img" aria-label="diagram preview">
                        <defs>
                          <marker id={arrowId} markerWidth="8" markerHeight="8" refX="7" refY="3.5" orient="auto">
                            <polygon points="0 0, 8 3.5, 0 7" />
                          </marker>
                        </defs>
                        <rect x="18" y="24" width="106" height="54" rx="12" />
                        <rect x="196" y="24" width="106" height="54" rx="12" />
                        <text x="71" y="56">{widget.from || "From"}</text>
                        <text x="249" y="56">{widget.to || "To"}</text>
                        <line x1="124" y1="51" x2="196" y2="51" markerEnd={`url(#${arrowId})`} />
                      </svg>
                      <div className="diagram-inputs">
                        <input
                          className="field-input"
                          value={widget.from}
                          onChange={(e) => handleUpdateDiagramWidget(widget.id, "from", e.target.value)}
                          placeholder="From"
                        />
                        <input
                          className="field-input"
                          value={widget.to}
                          onChange={(e) => handleUpdateDiagramWidget(widget.id, "to", e.target.value)}
                          placeholder="To"
                        />
                      </div>
                      <textarea
                        className="field-input widget-note"
                        value={widget.note}
                        onChange={(e) => handleUpdateDiagramWidget(widget.id, "note", e.target.value)}
                        placeholder="Diagram notes"
                      />
                    </article>
                  )
                })}
              </aside>
            )}
          </div>
        ) : (
          <div className="collapsed-note interactive">
            <div className="collapsed-title">
              {currentSession ? currentSession.name : "No active chat"}
            </div>
            <div className="collapsed-subtitle">Tap expand to open chat and widgets.</div>
          </div>
        )}
      </div>
    </div>
  )
}

export default Queue

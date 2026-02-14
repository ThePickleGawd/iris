import React, { useEffect, useMemo, useRef, useState } from "react"
import { useQuery } from "react-query"
import { MessageSquare, Settings, X, Mic, SendHorizontal } from "lucide-react"
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
import ModelSelector from "../components/ui/ModelSelector"
import ScreenshotQueue from "../components/Queue/ScreenshotQueue"
import { createRequestId } from "../lib/agentProtocol"
import type { AgentTransportMode, AgentTransportSettings } from "../lib/agentProtocol"
import { streamAgentResponse } from "../lib/agentTransport"

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

interface QueueProps {
  setView: React.Dispatch<React.SetStateAction<"queue" | "solutions" | "debug">>
}

type Panel = "chat" | "config"

const Queue: React.FC<QueueProps> = ({ setView }) => {
  const [toastOpen, setToastOpen] = useState(false)
  const [toastMessage, setToastMessage] = useState<ToastMessage>({
    title: "",
    description: "",
    variant: "neutral"
  })
  const [activePanel, setActivePanel] = useState<Panel>("chat")

  const [chatInput, setChatInput] = useState("")
  const [chatMessages, setChatMessages] = useState<{ role: "user" | "assistant"; text: string }[]>([])
  const [chatLoading, setChatLoading] = useState(false)
  const [isVoiceRecording, setIsVoiceRecording] = useState(false)
  const [isVoiceTranscribing, setIsVoiceTranscribing] = useState(false)
  const [notificationsEnabled, setNotificationsEnabled] = useState(true)
  const [soundPingEnabled, setSoundPingEnabled] = useState(true)
  const [transportMode, setTransportMode] = useState<AgentTransportMode>("direct")
  const [backendBaseUrl, setBackendBaseUrl] = useState("http://localhost:8787")
  const [backendStreamPath, setBackendStreamPath] = useState("/v1/agent/stream")
  const [workspaceId, setWorkspaceId] = useState("default-workspace")
  const [sessionId, setSessionId] = useState("default-session")
  const [backendAuthToken, setBackendAuthToken] = useState("")
  const [currentModel, setCurrentModel] = useState<{ provider: string; model: string }>({
    provider: "claude",
    model: "claude-sonnet-4-5"
  })

  const contentRef = useRef<HTMLDivElement>(null)
  const chatInputRef = useRef<HTMLInputElement>(null)
  const messageListRef = useRef<HTMLDivElement>(null)

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

  const chatHint = useMemo(() => {
    const source = transportMode === "direct" ? "Direct local transport" : `Backend transport (${backendBaseUrl})`
    return currentModel.provider === "ollama"
      ? `Local model: ${currentModel.model} • ${source}`
      : `Cloud model: ${currentModel.model} • ${source}`
  }, [currentModel, transportMode, backendBaseUrl])

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

  const sendChatMessage = async (message: string) => {
    const trimmed = message.trim()
    if (!trimmed) return

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
      mode: transportMode,
      backendBaseUrl: backendBaseUrl.trim(),
      backendStreamPath: backendStreamPath.trim() || "/v1/agent/stream",
      workspaceId: workspaceId.trim(),
      sessionId: sessionId.trim(),
      authToken: backendAuthToken.trim()
    }

    try {
      if (settings.mode === "backend" && !settings.backendBaseUrl) {
        throw new Error("Backend URL is required when Backend mode is enabled")
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
            if (text) setAssistantText(text)
          },
          onStatus: () => {},
          onToolCall: (name) => {
            console.log(`[AgentTool] call: ${name}`)
          },
          onToolResult: (name) => {
            console.log(`[AgentTool] result: ${name}`)
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
            await sendChatMessage(transcript)
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

  useEffect(() => {
    const loadCurrentModel = async () => {
      try {
        const config = await window.electronAPI.getCurrentLlmConfig()
        setCurrentModel({ provider: config.provider, model: config.model })
      } catch (error) {
        console.error("Error loading current model config:", error)
      }
    }
    loadCurrentModel()
  }, [])

  useEffect(() => {
    try {
      const savedNotifications = localStorage.getItem("iris_notifications_enabled")
      const savedSound = localStorage.getItem("iris_sound_ping_enabled")
      const savedTransportMode = localStorage.getItem("iris_transport_mode")
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
      if (savedTransportMode === "direct" || savedTransportMode === "backend") {
        setTransportMode(savedTransportMode)
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
      localStorage.setItem("iris_transport_mode", transportMode)
      localStorage.setItem("iris_backend_base_url", backendBaseUrl)
      localStorage.setItem("iris_backend_stream_path", backendStreamPath)
      localStorage.setItem("iris_workspace_id", workspaceId)
      localStorage.setItem("iris_session_id", sessionId)
      localStorage.setItem("iris_backend_auth_token", backendAuthToken)
    } catch {
      // ignore storage errors
    }
  }, [transportMode, backendBaseUrl, backendStreamPath, workspaceId, sessionId, backendAuthToken])

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
            setActivePanel("chat")
          }
        } catch (err) {
          setChatMessages((msgs) => [...msgs, { role: "assistant", text: "Error: " + String(err) }])
        } finally {
          setChatLoading(false)
        }
      }),
      window.electronAPI.onResetView(() => refetch()),
      window.electronAPI.onSolutionError((error: string) => {
        showToast("Processing Failed", "There was an error processing your screenshots.", "error")
        setView("queue")
        console.error("Processing error:", error)
      }),
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
  }, [refetch, setView, soundPingEnabled])

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

  const handleModelChange = (provider: "ollama" | "claude", model: string) => {
    setCurrentModel({ provider, model })
    setChatMessages((msgs) => [
      ...msgs,
      {
        role: "assistant",
        text: `Switched to ${provider === "ollama" ? "local" : "cloud"} model: ${model}`
      }
    ])
  }

  return (
    <div ref={contentRef} className="app-shell select-none">
      <Toast open={toastOpen} onOpenChange={setToastOpen} variant={toastMessage.variant} duration={3000}>
        <ToastTitle>{toastMessage.title}</ToastTitle>
        <ToastDescription>{toastMessage.description}</ToastDescription>
      </Toast>

      <div className="queue-layout p-3">
        <aside className="side-nav panel p-2">
          <button
            className={`side-btn ${activePanel === "chat" ? "side-btn-active" : ""}`}
            onClick={() => setActivePanel("chat")}
            title="Chat"
            aria-label="Chat"
          >
            <MessageSquare size={16} />
            <span>Chat</span>
          </button>
          <button
            className={`side-btn ${activePanel === "config" ? "side-btn-active" : ""}`}
            onClick={() => setActivePanel("config")}
            title="Config"
            aria-label="Config"
          >
            <Settings size={16} />
            <span>Config</span>
          </button>
          <button
            className="side-btn side-btn-danger"
            onClick={() => window.electronAPI.quitApp()}
            title="Exit"
            aria-label="Exit"
          >
            <X size={16} />
            <span>Exit</span>
          </button>
        </aside>

        <main className="panel main-pane p-4">
          {activePanel === "chat" ? (
            <div className="space-y-3">
              <div className="text-xs text-slate-500">{chatHint}</div>

              {screenshots.length > 0 && (
                <ScreenshotQueue
                  isLoading={chatLoading}
                  screenshots={screenshots}
                  onDeleteScreenshot={handleDeleteScreenshot}
                />
              )}

              <div ref={messageListRef} className="chat-log h-[300px] overflow-y-auto p-3">
                {chatMessages.length === 0 ? (
                  <div className="text-sm text-slate-500 text-center mt-10">
                    Start chatting, or use the mic button to transcribe and send.
                  </div>
                ) : (
                  chatMessages.map((msg, idx) => (
                    <div key={idx} className={`w-full flex ${msg.role === "user" ? "justify-end" : "justify-start"} mb-3`}>
                      <div className={`max-w-[82%] px-3 py-2 rounded-2xl text-xs border ${msg.role === "user" ? "message-user" : "message-assistant"}`}>
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
                  <div className="w-full flex justify-start mb-3">
                    <div className="message-assistant px-3 py-2 rounded-2xl text-xs border">Thinking...</div>
                  </div>
                )}
              </div>

              <form
                className="flex gap-2 items-center"
                onSubmit={(e) => {
                  e.preventDefault()
                  handleChatSend()
                }}
              >
                <input
                  ref={chatInputRef}
                  className="chat-input flex-1 rounded-xl px-3 py-2 text-xs focus:outline-none focus:ring-2 focus:ring-teal-700/30"
                  placeholder="Type a message..."
                  value={chatInput}
                  onChange={(e) => setChatInput(e.target.value)}
                  disabled={chatLoading || isVoiceRecording || isVoiceTranscribing}
                />
                <button
                  type="button"
                  className={`chat-mic p-2 rounded-xl flex items-center justify-center ${isVoiceRecording ? "chat-mic-recording" : ""}`}
                  onClick={handleVoiceTranscription}
                  disabled={chatLoading || isVoiceTranscribing}
                  aria-label={isVoiceRecording ? "Stop voice recording" : "Start voice recording"}
                  title={isVoiceRecording ? "Stop recording" : "Record and transcribe"}
                >
                  <Mic size={16} />
                </button>
                <button
                  type="submit"
                  className="chat-send p-2 rounded-xl flex items-center justify-center disabled:opacity-50"
                  disabled={chatLoading || isVoiceRecording || isVoiceTranscribing || !chatInput.trim()}
                  aria-label="Send"
                >
                  <SendHorizontal size={16} />
                </button>
              </form>
            </div>
          ) : (
            <div className="space-y-3">
              <h2 className="text-sm font-semibold text-slate-800">Configuration</h2>
              <p className="text-xs text-slate-500">Choose your provider and model.</p>
              <div className="panel p-3 space-y-3">
                <div className="text-xs font-semibold text-slate-700">Agent Transport</div>
                <div className="flex gap-2">
                  <button
                    type="button"
                    className={`px-3 py-2 text-xs rounded border ${transportMode === "direct" ? "bg-teal-700 text-white border-teal-800" : "bg-slate-100 text-slate-700 border-slate-300"}`}
                    onClick={() => setTransportMode("direct")}
                  >
                    Direct Claude
                  </button>
                  <button
                    type="button"
                    className={`px-3 py-2 text-xs rounded border ${transportMode === "backend" ? "bg-teal-700 text-white border-teal-800" : "bg-slate-100 text-slate-700 border-slate-300"}`}
                    onClick={() => setTransportMode("backend")}
                  >
                    Backend Agent
                  </button>
                </div>

                <div className="text-[11px] text-slate-500">
                  Contract: POST {`{backendBaseUrl}`}{backendStreamPath || "/v1/agent/stream"} with `agent.request` envelope, return stream events (`message.delta`, `message.final`, `status`, `tool.call`, `tool.result`, `error`).
                </div>

                <div className="grid grid-cols-1 gap-2">
                  <label className="text-xs text-slate-700">
                    Backend URL
                    <input
                      className="mt-1 w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
                      value={backendBaseUrl}
                      onChange={(e) => setBackendBaseUrl(e.target.value)}
                      placeholder="http://localhost:8787"
                      disabled={transportMode !== "backend"}
                    />
                  </label>
                  <label className="text-xs text-slate-700">
                    Stream Endpoint Path
                    <input
                      className="mt-1 w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
                      value={backendStreamPath}
                      onChange={(e) => setBackendStreamPath(e.target.value)}
                      placeholder="/v1/agent/stream"
                      disabled={transportMode !== "backend"}
                    />
                  </label>
                  <label className="text-xs text-slate-700">
                    Workspace ID
                    <input
                      className="mt-1 w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
                      value={workspaceId}
                      onChange={(e) => setWorkspaceId(e.target.value)}
                      placeholder="default-workspace"
                      disabled={transportMode !== "backend"}
                    />
                  </label>
                  <label className="text-xs text-slate-700">
                    Session ID
                    <input
                      className="mt-1 w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
                      value={sessionId}
                      onChange={(e) => setSessionId(e.target.value)}
                      placeholder="default-session"
                      disabled={transportMode !== "backend"}
                    />
                  </label>
                  <label className="text-xs text-slate-700">
                    Backend Auth Token (optional)
                    <input
                      type="password"
                      className="mt-1 w-full px-3 py-2 text-xs bg-white border border-slate-300 rounded focus:outline-none focus:ring-2 focus:ring-teal-700/20"
                      value={backendAuthToken}
                      onChange={(e) => setBackendAuthToken(e.target.value)}
                      placeholder="Bearer token"
                      disabled={transportMode !== "backend"}
                    />
                  </label>
                </div>
              </div>
              <div className="panel p-3 space-y-3">
                <label className="flex items-center justify-between text-xs text-slate-700">
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
                <label className="flex items-center justify-between text-xs text-slate-700">
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
              {transportMode === "direct" ? (
                <ModelSelector onModelChange={handleModelChange} onChatOpen={() => setActivePanel("chat")} />
              ) : (
                <div className="panel p-3 text-xs text-slate-600">
                  Local model controls are disabled in Backend Agent mode. Model selection should be handled by the backend session.
                </div>
              )}
            </div>
          )}
        </main>
      </div>
    </div>
  )
}

export default Queue

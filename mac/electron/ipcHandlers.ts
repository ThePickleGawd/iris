// ipcHandlers.ts

import { ipcMain, app, Notification } from "electron"
import http from "http"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { AppState } from "./main"
import { WidgetWindowManager, WidgetSpec } from "./WidgetWindowManager"
import { uploadScreenshotToBackend } from "./backendUploader"

const AGENT_SERVER_URL = process.env.IRIS_AGENT_URL || "http://localhost:8000"
const AGENT_STREAM_PATH = "/v1/agent/stream"

interface SessionInfo {
  id: string
  agent: string
  name: string
}

export function initializeIpcHandlers(appState: AppState): void {
  let notificationsEnabled = true
  let currentSession: SessionInfo | null = null
  let messagePollerInterval: ReturnType<typeof setInterval> | null = null
  let lastMessageTimestamp: string | null = null
  const widgetManager = new WidgetWindowManager()
  const getLatestScreenshotPathFromQueues = (): string | undefined => {
    const queue = appState.getScreenshotQueue()
    const extraQueue = appState.getExtraScreenshotQueue()
    const queueLatest = queue.length > 0 ? queue[queue.length - 1] : undefined
    const extraLatest = extraQueue.length > 0 ? extraQueue[extraQueue.length - 1] : undefined
    return extraLatest || queueLatest
  }

  const notifyAgentReply = (text: string) => {
    if (!notificationsEnabled) return
    try {
      if (Notification.isSupported()) {
        const n = new Notification({
          title: "Iris",
          body: (text || "Assistant replied").slice(0, 180),
          silent: false
        })
        n.show()
      }
    } catch (error) {
      console.error("Failed to show notification:", error)
    }
  }

  const resolveChatContext = () => ({
    chatId: currentSession?.id || `mac-${appState.deviceDiscovery.getDeviceId()}`,
    agent: currentSession?.agent || "iris"
  })

  const uploadScreenshotForAgentContext = async (
    screenshotPath: string,
    source: string
  ) => {
    const { chatId } = resolveChatContext()
    await uploadScreenshotToBackend(screenshotPath, {
      deviceId: "mac",
      sessionId: chatId,
      source
    }).catch(() => {})
  }

  const analyzeImageViaAgent = async (imagePath: string, userPrompt?: string) => {
    await uploadScreenshotForAgentContext(imagePath, "image-analysis")
    const prompt =
      userPrompt && userPrompt.trim()
        ? `Analyze the latest uploaded screenshot for this session and answer the user's request:\n"${userPrompt.trim()}".`
        : "Analyze the latest uploaded screenshot for this session and provide a concise, helpful summary with next actions."
    const text = await agentChatNonStreaming(prompt)
    return { text, timestamp: Date.now() }
  }

  const writeBase64ImageToTempFile = async (data: string, mimeType?: string): Promise<string> => {
    const ext =
      mimeType === "image/jpeg"
        ? "jpg"
        : mimeType === "image/webp"
          ? "webp"
          : mimeType === "image/gif"
            ? "gif"
            : "png"
    const tempPath = path.join(os.tmpdir(), `iris-image-${Date.now()}-${Math.random().toString(16).slice(2)}.${ext}`)
    const buffer = Buffer.from(data, "base64")
    await fs.promises.writeFile(tempPath, buffer)
    return tempPath
  }

  ipcMain.handle(
    "update-content-dimensions",
    async (event, { width, height }: { width: number; height: number }) => {
      if (width && height) {
        appState.setWindowDimensions(width, height)
      }
    }
  )

  ipcMain.handle("delete-screenshot", async (event, path: string) => {
    return appState.deleteScreenshot(path)
  })

  ipcMain.handle("take-screenshot", async () => {
    try {
      const screenshotPath = await appState.takeScreenshot()
      const preview = await appState.getImagePreview(screenshotPath)
      return { path: screenshotPath, preview }
    } catch (error) {
      console.error("Error taking screenshot:", error)
      throw error
    }
  })

  ipcMain.handle("get-screenshots", async () => {
    console.log({ view: appState.getView() })
    try {
      let previews = []
      if (appState.getView() === "queue") {
        previews = await Promise.all(
          appState.getScreenshotQueue().map(async (path) => ({
            path,
            preview: await appState.getImagePreview(path)
          }))
        )
      } else {
        previews = await Promise.all(
          appState.getExtraScreenshotQueue().map(async (path) => ({
            path,
            preview: await appState.getImagePreview(path)
          }))
        )
      }
      previews.forEach((preview: any) => console.log(preview.path))
      return previews
    } catch (error) {
      console.error("Error getting screenshots:", error)
      throw error
    }
  })

  ipcMain.handle("toggle-window", async () => {
    appState.toggleMainWindow()
  })

  ipcMain.handle("reset-queues", async () => {
    try {
      appState.clearQueues()
      console.log("Screenshot queues have been cleared.")
      return { success: true }
    } catch (error: any) {
      console.error("Error resetting queues:", error)
      return { success: false, error: error.message }
    }
  })

  // IPC handler for analyzing audio from base64 data
  ipcMain.handle("analyze-audio-base64", async (event, data: string, mimeType: string) => {
    try {
      const result = await appState.processingHelper.processAudioBase64(data, mimeType)
      return result
    } catch (error: any) {
      console.error("Error in analyze-audio-base64 handler:", error)
      throw error
    }
  })

  // IPC handler for analyzing audio from file path
  ipcMain.handle("analyze-audio-file", async (event, path: string) => {
    try {
      const result = await appState.processingHelper.processAudioFile(path)
      return result
    } catch (error: any) {
      console.error("Error in analyze-audio-file handler:", error)
      throw error
    }
  })

  // IPC handler for analyzing image from file path
  ipcMain.handle("analyze-image-file", async (_, imagePath: string) => {
    try {
      return await analyzeImageViaAgent(imagePath)
    } catch (error: any) {
      console.error("Error in analyze-image-file handler:", error)
      throw error
    }
  })

  // IPC handler for analyzing image from base64 data
  ipcMain.handle("analyze-image-base64", async (_, data: string, mimeType: string, userPrompt?: string) => {
    let tempPath: string | null = null
    try {
      tempPath = await writeBase64ImageToTempFile(data, mimeType)
      return await analyzeImageViaAgent(tempPath, userPrompt)
    } catch (error: any) {
      console.error("Error in analyze-image-base64 handler:", error)
      throw error
    } finally {
      if (tempPath) {
        fs.promises.unlink(tempPath).catch(() => {})
      }
    }
  })

  ipcMain.handle("claude-chat", async (event, message: string) => {
    try {
      // Upload latest screenshot to backend before sending chat
      const latestScreenshotPath = getLatestScreenshotPathFromQueues()
      if (latestScreenshotPath) {
        await uploadScreenshotForAgentContext(latestScreenshotPath, "chat-context")
      }

      // Route through Agents Server
      const result = await agentChatNonStreaming(message)
      notifyAgentReply(result)
      event.sender.send("agent-reply", { text: result })
      return result
    } catch (error: any) {
      console.error("Error in claude-chat handler:", error)
      throw error
    }
  });

  ipcMain.handle("claude-chat-stream", async (event, requestId: string, message: string) => {
    try {
      // Upload latest screenshot to backend before sending chat
      const latestScreenshotPath = getLatestScreenshotPathFromQueues()
      if (latestScreenshotPath) {
        await uploadScreenshotForAgentContext(latestScreenshotPath, "chat-context")
      }

      // Route through Agents Server SSE endpoint
      const full = await agentChatStream(message, (chunk) => {
        event.sender.send("claude-chat-stream-chunk", { requestId, chunk })
      })
      notifyAgentReply(full)
      event.sender.send("agent-reply", { text: full })
      event.sender.send("claude-chat-stream-done", { requestId, text: full })
      return { success: true }
    } catch (error: any) {
      event.sender.send("claude-chat-stream-error", {
        requestId,
        error: error?.message || String(error)
      })
      return { success: false, error: error?.message || String(error) }
    }
  });

  ipcMain.handle("quit-app", () => {
    app.quit()
  })

  ipcMain.handle("set-notifications-enabled", async (_, enabled: boolean) => {
    notificationsEnabled = Boolean(enabled)
    return { success: true }
  })

  ipcMain.handle("open-widget", async (_, spec: WidgetSpec) => {
    return widgetManager.openWidget(spec)
  })

  // ─── Session Management ─────────────────────────────────

  function agentServerGet(path: string): Promise<any> {
    return new Promise((resolve, reject) => {
      const parsed = new URL(`${AGENT_SERVER_URL}${path}`)
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: parsed.port,
          path: parsed.pathname + parsed.search,
          method: "GET",
          timeout: 10_000,
        },
        (res) => {
          let data = ""
          res.on("data", (chunk) => (data += chunk))
          res.on("end", () => {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              try { resolve(JSON.parse(data)) } catch { resolve(data) }
            } else {
              reject(new Error(`Agent server error ${res.statusCode}: ${data.slice(0, 300)}`))
            }
          })
        }
      )
      req.on("error", reject)
      req.on("timeout", () => { req.destroy(); reject(new Error("Agent server timeout")) })
      req.end()
    })
  }

  function agentServerPost(path: string, body: unknown): Promise<any> {
    return new Promise((resolve, reject) => {
      const bodyStr = JSON.stringify(body)
      const parsed = new URL(`${AGENT_SERVER_URL}${path}`)
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: parsed.port,
          path: parsed.pathname,
          method: "POST",
          headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(bodyStr) },
          timeout: 10_000,
        },
        (res) => {
          let data = ""
          res.on("data", (chunk) => (data += chunk))
          res.on("end", () => {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              try { resolve(JSON.parse(data)) } catch { resolve(data) }
            } else {
              reject(new Error(`Agent server error ${res.statusCode}: ${data.slice(0, 300)}`))
            }
          })
        }
      )
      req.on("error", reject)
      req.on("timeout", () => { req.destroy(); reject(new Error("Agent server timeout")) })
      req.write(bodyStr)
      req.end()
    })
  }

  ipcMain.handle("get-sessions", async () => {
    try {
      return await agentServerGet("/sessions?limit=50")
    } catch (error: any) {
      console.error("Failed to fetch sessions:", error)
      return { items: [], count: 0 }
    }
  })

  ipcMain.handle("get-current-session", async () => {
    return currentSession
  })

  ipcMain.handle("set-current-session", async (_, session: SessionInfo | null) => {
    currentSession = session
    lastMessageTimestamp = null
    startMessagePoller()
    return { success: true }
  })

  ipcMain.handle("create-session", async (_, params: { id: string; name: string; agent: string }) => {
    try {
      const result = await agentServerPost("/sessions", params)
      currentSession = { id: params.id, name: params.name, agent: params.agent }
      lastMessageTimestamp = null
      startMessagePoller()
      return result
    } catch (error: any) {
      console.error("Failed to create session:", error)
      return { error: error.message }
    }
  })

  ipcMain.handle("get-session-messages", async (_, sessionId: string, since?: string) => {
    try {
      const qs = since ? `?since=${encodeURIComponent(since)}&limit=200` : "?limit=200"
      return await agentServerGet(`/sessions/${sessionId}/messages${qs}`)
    } catch (error: any) {
      console.error("Failed to fetch session messages:", error)
      return { items: [], count: 0 }
    }
  })

  function startMessagePoller() {
    if (messagePollerInterval) {
      clearInterval(messagePollerInterval)
      messagePollerInterval = null
    }
    if (!currentSession) return

    messagePollerInterval = setInterval(async () => {
      if (!currentSession) return
      try {
        const qs = lastMessageTimestamp
          ? `?since=${encodeURIComponent(lastMessageTimestamp)}&limit=200`
          : "?limit=200"
        const data = await agentServerGet(`/sessions/${currentSession.id}/messages${qs}`)
        const items = data?.items || []
        if (items.length > 0) {
          lastMessageTimestamp = items[items.length - 1].created_at
          const mainWindow = appState.getMainWindow()
          mainWindow?.webContents.send("session-messages-update", {
            sessionId: currentSession.id,
            messages: items,
          })
        }
      } catch {
        // Polling failure is non-fatal
      }
    }, 3000)
  }

  // Window movement handlers
  ipcMain.handle("move-window-left", async () => {
    appState.moveWindowLeft()
  })

  ipcMain.handle("move-window-right", async () => {
    appState.moveWindowRight()
  })

  ipcMain.handle("move-window-up", async () => {
    appState.moveWindowUp()
  })

  ipcMain.handle("move-window-down", async () => {
    appState.moveWindowDown()
  })

  ipcMain.handle("center-and-show-window", async () => {
    appState.centerAndShowWindow()
  })

  // ─── Agent Server Helpers ─────────────────────────────────

  function buildAgentRequestEnvelope(message: string, chatId: string, agent: string) {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
    return {
      protocol_version: "1.0",
      kind: "agent.request",
      request_id: requestId,
      timestamp: new Date().toISOString(),
      workspace_id: chatId,
      session_id: chatId,
      device: {
        id: appState.deviceDiscovery.getDeviceId(),
        name: os.hostname(),
        platform: process.platform,
        app_version: app.getVersion()
      },
      input: {
        type: "text",
        text: message
      },
      context: {
        recent_messages: [] as Array<{ role: "user" | "assistant"; text: string }>
      },
      metadata: {
        agent
      }
    }
  }

  function agentChatNonStreaming(message: string): Promise<string> {
    return agentChatStream(message, () => {})
  }

  function agentChatStream(message: string, onChunk: (chunk: string) => void): Promise<string> {
    return new Promise((resolve, reject) => {
      const { chatId, agent } = resolveChatContext()
      const envelope = buildAgentRequestEnvelope(message, chatId, agent)
      const body = JSON.stringify(envelope)
      const parsed = new URL(`${AGENT_SERVER_URL}${AGENT_STREAM_PATH}`)

      const req = http.request(
        {
          hostname: parsed.hostname,
          port: parsed.port,
          path: parsed.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(body),
            "Accept": "text/event-stream, application/x-ndjson, application/json",
          },
          timeout: 120_000,
        },
        (res) => {
          if (res.statusCode && res.statusCode >= 400) {
            let errData = ""
            res.on("data", (chunk) => (errData += chunk))
            res.on("end", () => reject(new Error(`Agent server error ${res.statusCode}: ${errData.slice(0, 300)}`)))
            return
          }

          let buffer = ""
          let fullText = ""
          let streamError: string | null = null

          res.on("data", (chunk: Buffer) => {
            buffer += chunk.toString()
            const lines = buffer.split("\n")
            buffer = lines.pop() || ""

            for (const line of lines) {
              const trimmed = line.trim()
              if (!trimmed) continue
              const payload = trimmed.startsWith("data:") ? trimmed.slice(5).trim() : trimmed
              if (!payload || payload === "[DONE]") continue

              try {
                const event = JSON.parse(payload)
                if (event.kind === "message.delta" && event.delta) {
                  fullText += event.delta
                  onChunk(event.delta)
                } else if (event.kind === "message.final" && event.text) {
                  fullText = event.text
                } else if (event.kind === "error" && event.message) {
                  streamError = String(event.message)
                } else if (typeof event.chunk === "string") {
                  fullText += event.chunk
                  onChunk(event.chunk)
                } else if (typeof event.text === "string") {
                  fullText = event.text
                } else if (typeof event.error === "string") {
                  streamError = event.error
                }
              } catch {
                // ignore malformed SSE lines
              }
            }
          })

          res.on("end", () => {
            if (streamError) {
              reject(new Error(streamError))
              return
            }
            resolve(fullText)
          })
          res.on("error", reject)
        }
      )
      req.on("error", reject)
      req.on("timeout", () => { req.destroy(); reject(new Error("Agent server stream timeout")) })
      req.write(body)
      req.end()
    })
  }

  // ─── Network Info & Direct Connection ─────────────────────

  ipcMain.handle("get-network-info", async () => {
    const os = require("os")
    const interfaces = os.networkInterfaces()
    const ips: string[] = []
    for (const name of Object.keys(interfaces)) {
      for (const iface of interfaces[name] || []) {
        if (iface.family === "IPv4" && !iface.internal) {
          ips.push(iface.address)
        }
      }
    }
    return {
      macIp: ips[0] || "unknown",
      allIps: ips,
      hostname: os.hostname(),
      connectedDevices: appState.deviceDiscovery.getDevices(),
    }
  })

  ipcMain.handle("connect-ipad", async (_, host: string, port?: number) => {
    try {
      await appState.deviceDiscovery.connectDirect(host, port || 8935)
      return { success: true }
    } catch (error: any) {
      return { success: false, error: error.message || String(error) }
    }
  })

  // ─── Device Discovery (Iris iPad) ─────────────────────────

  ipcMain.handle("get-iris-devices", async () => {
    return appState.deviceDiscovery.getDevices()
  })

  ipcMain.handle("get-iris-device", async (_, id: string) => {
    return appState.deviceDiscovery.getDevice(id) || null
  })

  ipcMain.handle("get-primary-iris-device", async () => {
    return appState.deviceDiscovery.getPrimaryDevice() || null
  })

  ipcMain.handle("get-mac-device-id", async () => {
    return appState.deviceDiscovery.getDeviceId()
  })

  // Forward discovery events to renderer
  const discovery = appState.deviceDiscovery
  discovery.on("device-found", (device) => {
    const mainWindow = appState.getMainWindow()
    mainWindow?.webContents.send("iris-device-found", device)
  })
  discovery.on("device-lost", (deviceId) => {
    const mainWindow = appState.getMainWindow()
    mainWindow?.webContents.send("iris-device-lost", deviceId)
  })
  discovery.on("device-updated", (device) => {
    const mainWindow = appState.getMainWindow()
    mainWindow?.webContents.send("iris-device-updated", device)
  })
}

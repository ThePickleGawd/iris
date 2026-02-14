// ipcHandlers.ts

import { ipcMain, app, Notification } from "electron"
import http from "http"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawn } from "node:child_process"
import { AppState } from "./main"
import { WidgetWindowManager, WidgetSpec } from "./WidgetWindowManager"
import { uploadScreenshotToBackend } from "./backendUploader"

const AGENT_SERVER_URL = process.env.IRIS_AGENT_URL || "http://localhost:8000"
const AGENT_CHAT_PATH = "/v1/agent"
const AGENT_GET_TIMEOUT_MS = Number(process.env.IRIS_AGENT_GET_TIMEOUT_MS || 6000)
const AGENT_POST_TIMEOUT_MS = Number(process.env.IRIS_AGENT_POST_TIMEOUT_MS || 10000)
const AGENT_CHAT_TIMEOUT_MS = Number(process.env.IRIS_AGENT_CHAT_TIMEOUT_MS || 120000)
const AGENT_GET_RETRIES = Number(process.env.IRIS_AGENT_GET_RETRIES || 1)

interface SessionInfo {
  id: string
  model: string
  name: string
  metadata?: {
    claude_code_conversation_id?: string
    codex_conversation_id?: string
    codex_cwd?: string
  }
}

interface CodexSessionInfo {
  id: string
  title: string
  timestamp?: string
  cwd?: string
}

interface ClaudeCodeSessionInfo {
  id: string
  title: string
  timestamp?: string
  cwd?: string
}

export function initializeIpcHandlers(appState: AppState): void {
  let notificationsEnabled = true
  let currentSession: SessionInfo | null = null
  let messagePollerInterval: ReturnType<typeof setInterval> | null = null
  let lastMessageTimestamp: string | null = null
  let isPollingMessages = false
  let pollFailures = 0
  let sessionsCache: { items: any[]; count: number } = { items: [], count: 0 }
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
    model: currentSession?.model || "gpt-5.2"
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

  ipcMain.handle("get-codex-sessions", async () => {
    try {
      const sessionsRoot = path.join(os.homedir(), ".codex", "sessions")
      const files: string[] = []

      const walk = async (dir: string): Promise<void> => {
        const entries = await fs.promises.readdir(dir, { withFileTypes: true })
        await Promise.all(entries.map(async (entry) => {
          const fullPath = path.join(dir, entry.name)
          if (entry.isDirectory()) {
            await walk(fullPath)
            return
          }
          if (entry.isFile() && entry.name.endsWith(".jsonl")) {
            files.push(fullPath)
          }
        }))
      }

      await walk(sessionsRoot)
      files.sort((a, b) => b.localeCompare(a))

      const out: CodexSessionInfo[] = []
      const seen = new Set<string>()
      for (const filePath of files.slice(0, 200)) {
        try {
          const raw = await fs.promises.readFile(filePath, "utf-8")
          const firstLine = raw.split("\n")[0] || ""
          const parsed = JSON.parse(firstLine)
          const payload = parsed?.payload || {}
          const id = String(payload.id || "").trim()
          if (!id || seen.has(id)) continue
          seen.add(id)

          const cwd = typeof payload.cwd === "string" ? payload.cwd : ""
          const baseName = cwd ? path.basename(cwd) : "Codex Session"
          const timestamp = typeof payload.timestamp === "string" ? payload.timestamp : undefined
          out.push({
            id,
            title: baseName,
            timestamp,
            cwd: cwd || undefined,
          })
        } catch {
          // ignore malformed entries
        }
      }

      return out
    } catch {
      return []
    }
  })

  ipcMain.handle("get-claude-code-sessions", async () => {
    try {
      const sessionsRoot = path.join(os.homedir(), ".claude", "projects")
      const files: string[] = []

      const walk = async (dir: string): Promise<void> => {
        const entries = await fs.promises.readdir(dir, { withFileTypes: true })
        await Promise.all(entries.map(async (entry) => {
          const fullPath = path.join(dir, entry.name)
          if (entry.isDirectory()) {
            await walk(fullPath)
            return
          }
          if (entry.isFile() && entry.name.endsWith(".jsonl")) {
            files.push(fullPath)
          }
        }))
      }

      await walk(sessionsRoot)
      files.sort((a, b) => b.localeCompare(a))

      const out: ClaudeCodeSessionInfo[] = []
      const seen = new Set<string>()
      for (const filePath of files.slice(0, 300)) {
        try {
          const raw = await fs.promises.readFile(filePath, "utf-8")
          const lines = raw.split("\n")
          let id = ""
          let timestamp: string | undefined
          let cwd: string | undefined

          for (const line of lines) {
            const trimmed = line.trim()
            if (!trimmed.startsWith("{")) continue
            const parsed = JSON.parse(trimmed)
            const sessionId = typeof parsed?.sessionId === "string" ? parsed.sessionId.trim() : ""
            if (sessionId && !id) id = sessionId
            if (!timestamp && typeof parsed?.timestamp === "string") {
              timestamp = parsed.timestamp
            }
            if (!cwd && typeof parsed?.cwd === "string" && parsed.cwd.trim()) {
              cwd = parsed.cwd.trim()
            }
            if (id && timestamp && cwd) break
          }

          if (!id || seen.has(id)) continue
          seen.add(id)

          const baseName = cwd ? path.basename(cwd) : "Claude Code Session"
          out.push({
            id,
            title: baseName,
            timestamp,
            cwd,
          })
        } catch {
          // ignore malformed entries
        }
      }

      return out
    } catch {
      return []
    }
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

  // Legacy IPC name retained for compatibility, but handled as non-streaming HTTP.
  ipcMain.handle("claude-chat-stream", async (event, requestId: string, message: string) => {
    try {
      const latestScreenshotPath = getLatestScreenshotPathFromQueues()
      if (latestScreenshotPath) {
        await uploadScreenshotForAgentContext(latestScreenshotPath, "chat-context")
      }

      const full = await agentChatNonStreaming(message)
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

  async function agentServerGet(path: string): Promise<any> {
    const attempts = Math.max(0, AGENT_GET_RETRIES) + 1
    let lastError: unknown
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      try {
        return await requestAgentServer("GET", path, undefined, AGENT_GET_TIMEOUT_MS)
      } catch (error) {
        lastError = error
        if (!isRetryableNetworkError(error) || attempt === attempts - 1) {
          break
        }
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError))
  }

  function agentServerPost(path: string, body: unknown): Promise<any> {
    return requestAgentServer("POST", path, body, AGENT_POST_TIMEOUT_MS)
  }

  function requestAgentServer(
    method: "GET" | "POST" | "DELETE",
    path: string,
    body?: unknown,
    timeoutMs: number = AGENT_GET_TIMEOUT_MS
  ): Promise<any> {
    return new Promise((resolve, reject) => {
      const parsed = new URL(`${AGENT_SERVER_URL}${path}`)
      const bodyStr = body === undefined ? "" : JSON.stringify(body)
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: parsed.port,
          path: parsed.pathname + parsed.search,
          method,
          headers:
            (method === "POST" || method === "DELETE") && body !== undefined
              ? {
                  "Content-Type": "application/json",
                  "Content-Length": Buffer.byteLength(bodyStr),
                }
              : undefined,
          timeout: timeoutMs,
        },
        (res) => {
          let data = ""
          res.on("data", (chunk) => (data += chunk))
          res.on("end", () => {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              try {
                resolve(JSON.parse(data))
              } catch {
                resolve(data)
              }
            } else {
              reject(new Error(`Agent server error ${res.statusCode}: ${data.slice(0, 300)}`))
            }
          })
        }
      )
      req.on("error", reject)
      req.on("timeout", () => {
        req.destroy(new Error(`Agent server timeout (${timeoutMs}ms)`))
      })
      if ((method === "POST" || method === "DELETE") && body !== undefined) req.write(bodyStr)
      req.end()
    })
  }

  ipcMain.handle("get-sessions", async () => {
    try {
      const data = await agentServerGet("/sessions?limit=50")
      if (data && Array.isArray(data.items)) {
        const normalizedItems = data.items.map((item: any) => {
          const model = item?.model || item?.agent || "gpt-5.2"
          return { ...item, model, agent: model }
        })
        sessionsCache = {
          items: normalizedItems,
          count: typeof data.count === "number" ? data.count : normalizedItems.length,
        }
      }
      return sessionsCache
    } catch (error: any) {
      console.warn("Failed to fetch sessions:", error?.message || String(error))
      // Keep UI stable while backend is transiently unavailable.
      return sessionsCache
    }
  })

  ipcMain.handle("get-current-session", async () => {
    return currentSession
  })

  ipcMain.handle("set-current-session", async (_, session: SessionInfo | null) => {
    if (session) {
      const normalizedModel = (session.model || (session as any).agent || "gpt-5.2").trim()
      currentSession = {
        ...session,
        model: normalizedModel || "gpt-5.2",
      }
    } else {
      currentSession = null
    }
    lastMessageTimestamp = null
    startMessagePoller()
    return { success: true }
  })

  ipcMain.handle(
    "create-session",
    async (
      _,
      params: {
        id: string
        name: string
        model: string
        metadata?: {
          claude_code_conversation_id?: string
          codex_conversation_id?: string
          codex_cwd?: string
        }
      }
    ) => {
    try {
      const model = (params.model || (params as any).agent || "gpt-5.2").trim() || "gpt-5.2"
      const body = {
        id: params.id,
        name: params.name,
        model,
        agent: model,
        metadata: params.metadata || undefined,
      }
      const result = await agentServerPost("/sessions", body)
      currentSession = { id: params.id, name: params.name, model, metadata: params.metadata }
      lastMessageTimestamp = null
      startMessagePoller()
      return result
    } catch (error: any) {
      console.error("Failed to create session:", error)
      return { error: error.message }
    }
  })

  ipcMain.handle(
    "create-session-message",
    async (
      _,
      params: {
        sessionId: string
        role: "user" | "assistant"
        content: string
        deviceId?: string
      }
    ) => {
      try {
        const sessionId = String(params?.sessionId || "").trim()
        const role = params?.role
        const content = String(params?.content || "").trim()
        if (!sessionId) return { error: "sessionId is required" }
        if (role !== "user" && role !== "assistant") return { error: "role must be 'user' or 'assistant'" }
        if (!content) return { error: "content is required" }

        return await agentServerPost(`/sessions/${encodeURIComponent(sessionId)}/messages`, {
          role,
          content,
          device_id: params?.deviceId || undefined,
        })
      } catch (error: any) {
        console.error("Failed to create session message:", error)
        return { error: error?.message || String(error) }
      }
    }
  )

  ipcMain.handle(
    "send-codex-message",
    async (
      _,
      params: {
        conversationId: string
        prompt: string
        cwd?: string
      }
    ) => {
      const conversationId = String(params?.conversationId || "").trim()
      const prompt = String(params?.prompt || "").trim()
      const cwd = String(params?.cwd || "").trim()
      if (!conversationId) {
        throw new Error("Codex conversation id is required")
      }
      if (!prompt) {
        throw new Error("Prompt is required")
      }

      const lastMessagePath = path.join(
        os.tmpdir(),
        `iris-codex-last-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`
      )

      const args = ["exec", "--output-last-message", lastMessagePath]
      if (cwd) {
        args.push("--cd", cwd)
      }
      args.push("resume", conversationId, prompt, "--json", "--skip-git-repo-check")

      const run = await new Promise<{ exitCode: number; stdout: string; stderr: string }>((resolve, reject) => {
        const child = spawn("codex", args, {
          cwd: cwd || undefined,
          env: process.env,
        })
        let stdout = ""
        let stderr = ""
        child.stdout.on("data", (chunk) => {
          stdout += chunk.toString()
        })
        child.stderr.on("data", (chunk) => {
          stderr += chunk.toString()
        })
        child.on("error", reject)
        child.on("close", (code) => {
          resolve({
            exitCode: typeof code === "number" ? code : 1,
            stdout,
            stderr,
          })
        })
      })

      let text = ""
      try {
        text = (await fs.promises.readFile(lastMessagePath, "utf-8")).trim()
      } catch {
        text = ""
      } finally {
        fs.promises.unlink(lastMessagePath).catch(() => {})
      }

      if (run.exitCode !== 0) {
        const detail = extractCodexError(run.stderr) || extractCodexError(run.stdout)
        throw new Error(detail || `Codex exited with status ${run.exitCode}`)
      }

      if (!text) {
        const detail = extractCodexError(run.stderr) || extractCodexError(run.stdout)
        throw new Error(detail || "Codex returned no assistant text")
      }

      return { text }
    }
  )

  ipcMain.handle("delete-session", async (_, sessionId: string) => {
    try {
      await requestAgentServer("DELETE", `/sessions/${sessionId}`, undefined, AGENT_POST_TIMEOUT_MS)
      if (currentSession?.id === sessionId) {
        currentSession = null
        lastMessageTimestamp = null
        if (messagePollerInterval) {
          clearInterval(messagePollerInterval)
          messagePollerInterval = null
        }
      }
      return { success: true }
    } catch (error: any) {
      console.error("Failed to delete session:", error)
      return { success: false, error: error.message }
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
      if (!currentSession || isPollingMessages) return
      isPollingMessages = true
      try {
        const qs = lastMessageTimestamp
          ? `?since=${encodeURIComponent(lastMessageTimestamp)}&limit=200`
          : "?limit=200"
        const data = await agentServerGet(`/sessions/${currentSession.id}/messages${qs}`)
        pollFailures = 0
        const items = data?.items || []
        if (items.length > 0) {
          lastMessageTimestamp = items[items.length - 1].created_at
          const mainWindow = appState.getMainWindow()
          mainWindow?.webContents.send("session-messages-update", {
            sessionId: currentSession.id,
            messages: items,
          })
        }
      } catch (error: any) {
        pollFailures += 1
        if (pollFailures === 1 || pollFailures % 10 === 0) {
          console.warn("Session poll failed:", error?.message || String(error))
        }
      } finally {
        isPollingMessages = false
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

  ipcMain.handle("move-window-by", async (_, dx: number, dy: number) => {
    appState.moveWindowBy(dx, dy)
  })

  ipcMain.handle("center-and-show-window", async () => {
    appState.centerAndShowWindow()
  })

  // ─── Agent Server Helpers ─────────────────────────────────

  function buildAgentRequestEnvelope(message: string, chatId: string, model: string) {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
    const claudeCodeConversationId = currentSession?.metadata?.claude_code_conversation_id?.trim() || ""
    const codexConversationId = currentSession?.metadata?.codex_conversation_id?.trim() || ""
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
      model,
      metadata: {
        model,
        agent: model,
        ...(claudeCodeConversationId ? { claude_code_conversation_id: claudeCodeConversationId } : {}),
        ...(codexConversationId ? { codex_conversation_id: codexConversationId } : {}),
      }
    }
  }

  async function agentChatNonStreaming(message: string): Promise<string> {
    const { chatId, model } = resolveChatContext()
    const envelope = buildAgentRequestEnvelope(message, chatId, model)
    const result = await requestAgentServer("POST", AGENT_CHAT_PATH, envelope, AGENT_CHAT_TIMEOUT_MS)
    const text = typeof result?.text === "string" ? result.text : ""
    if (!text) {
      throw new Error("Agent server returned no text")
    }
    return text
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

function isRetryableNetworkError(error: unknown): boolean {
  if (!(error instanceof Error)) return false
  const msg = error.message.toLowerCase()
  return (
    msg.includes("timeout") ||
    msg.includes("econnreset") ||
    msg.includes("econnrefused") ||
    msg.includes("socket hang up")
  )
}

function extractCodexError(raw: string): string | null {
  const lines = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
  let fallback = ""
  for (const line of lines) {
    if (line.startsWith("{") && line.endsWith("}")) {
      try {
        const parsed = JSON.parse(line)
        if (parsed?.type === "error" && typeof parsed?.message === "string" && parsed.message.trim()) {
          return parsed.message.trim()
        }
        const nested = parsed?.error?.message
        if (typeof nested === "string" && nested.trim()) {
          fallback = nested.trim()
        }
      } catch {
        // ignore malformed line
      }
      continue
    }
    if (line.startsWith("WARNING:")) continue
    if (line.includes("codex_core::")) continue
    fallback = line
  }
  return fallback || null
}

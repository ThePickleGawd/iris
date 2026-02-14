import { contextBridge, ipcRenderer } from "electron"

// Types for the exposed Electron API
interface ElectronAPI {
  updateContentDimensions: (dimensions: {
    width: number
    height: number
  }) => Promise<void>
  getScreenshots: () => Promise<Array<{ path: string; preview: string }>>
  deleteScreenshot: (
    path: string
  ) => Promise<{ success: boolean; error?: string }>
  onScreenshotTaken: (
    callback: (data: { path: string; preview: string }) => void
  ) => () => void
  onSolutionsReady: (callback: (solutions: string) => void) => () => void
  onResetView: (callback: () => void) => () => void
  onSolutionStart: (callback: () => void) => () => void
  onDebugStart: (callback: () => void) => () => void
  onDebugSuccess: (callback: (data: any) => void) => () => void
  onSolutionError: (callback: (error: string) => void) => () => void
  onProcessingNoScreenshots: (callback: () => void) => () => void
  onProblemExtracted: (callback: (data: any) => void) => () => void
  onSolutionSuccess: (callback: (data: any) => void) => () => void

  onUnauthorized: (callback: () => void) => () => void
  onDebugError: (callback: (error: string) => void) => () => void
  takeScreenshot: () => Promise<void>
  moveWindowLeft: () => Promise<void>
  moveWindowRight: () => Promise<void>
  moveWindowUp: () => Promise<void>
  moveWindowDown: () => Promise<void>
  moveWindowBy: (dx: number, dy: number) => Promise<void>
  toggleWindow: () => Promise<void>
  analyzeAudioFromBase64: (data: string, mimeType: string) => Promise<{ text: string; timestamp: number }>
  analyzeAudioFile: (path: string) => Promise<{ text: string; timestamp: number }>
  analyzeImageFile: (path: string) => Promise<void>
  quitApp: () => Promise<void>
  onAgentReply: (callback: (data: { text: string }) => void) => () => void
  setNotificationsEnabled: (enabled: boolean) => Promise<{ success: boolean }>
  openWidget: (spec: {
    id?: string
    title?: string
    kind: "html" | "markdown" | "text" | "image" | "chart"
    width?: number
    height?: number
    css?: string
    payload: {
      html?: string
      markdown?: string
      text?: string
      imageUrl?: string
      chartConfig?: unknown
    }
  }) => Promise<{ success: boolean; id: string; error?: string }>
  
  // Session Management
  getSessions: () => Promise<{ items: any[]; count: number }>
  getCurrentSession: () => Promise<{
    id: string
    model: string
    name: string
    metadata?: {
      claude_code_conversation_id?: string
      codex_conversation_id?: string
      codex_cwd?: string
    }
  } | null>
  setCurrentSession: (session: {
    id: string
    model: string
    name: string
    metadata?: {
      claude_code_conversation_id?: string
      codex_conversation_id?: string
      codex_cwd?: string
    }
  } | null) => Promise<{ success: boolean }>
  createSession: (params: {
    id: string
    name: string
    model: string
    metadata?: {
      claude_code_conversation_id?: string
      codex_conversation_id?: string
      codex_cwd?: string
    }
  }) => Promise<any>
  getCodexSessions: () => Promise<Array<{ id: string; title: string; timestamp?: string; cwd?: string }>>
  getClaudeCodeSessions: () => Promise<Array<{ id: string; title: string; timestamp?: string; cwd?: string }>>
  sendCodexMessage: (params: { conversationId: string; prompt: string; cwd?: string }) => Promise<{ text: string }>
  createSessionMessage: (params: {
    sessionId: string
    role: "user" | "assistant"
    content: string
    deviceId?: string
  }) => Promise<any>
  getSessionMessages: (sessionId: string, since?: string) => Promise<{ items: any[]; count: number }>
  onSessionMessagesUpdate: (callback: (data: { sessionId: string; messages: any[] }) => void) => () => void

  // Iris Device Discovery
  getIrisDevices: () => Promise<any[]>
  getIrisDevice: (id: string) => Promise<any | null>
  getPrimaryIrisDevice: () => Promise<any | null>
  getMacDeviceId: () => Promise<string>
  onIrisDeviceFound: (callback: (device: any) => void) => () => void
  onIrisDeviceLost: (callback: (deviceId: string) => void) => () => void
  onIrisDeviceUpdated: (callback: (device: any) => void) => () => void

  invoke: (channel: string, ...args: any[]) => Promise<any>
}

export const PROCESSING_EVENTS = {
  //global states
  UNAUTHORIZED: "procesing-unauthorized",
  NO_SCREENSHOTS: "processing-no-screenshots",

  //states for generating the initial solution
  INITIAL_START: "initial-start",
  PROBLEM_EXTRACTED: "problem-extracted",
  SOLUTION_SUCCESS: "solution-success",
  INITIAL_SOLUTION_ERROR: "solution-error",

  //states for processing the debugging
  DEBUG_START: "debug-start",
  DEBUG_SUCCESS: "debug-success",
  DEBUG_ERROR: "debug-error"
} as const

// Expose the Electron API to the renderer process
contextBridge.exposeInMainWorld("electronAPI", {
  updateContentDimensions: (dimensions: { width: number; height: number }) =>
    ipcRenderer.invoke("update-content-dimensions", dimensions),
  takeScreenshot: () => ipcRenderer.invoke("take-screenshot"),
  getScreenshots: () => ipcRenderer.invoke("get-screenshots"),
  deleteScreenshot: (path: string) =>
    ipcRenderer.invoke("delete-screenshot", path),

  // Event listeners
  onScreenshotTaken: (
    callback: (data: { path: string; preview: string }) => void
  ) => {
    const subscription = (_: any, data: { path: string; preview: string }) =>
      callback(data)
    ipcRenderer.on("screenshot-taken", subscription)
    return () => {
      ipcRenderer.removeListener("screenshot-taken", subscription)
    }
  },
  onSolutionsReady: (callback: (solutions: string) => void) => {
    const subscription = (_: any, solutions: string) => callback(solutions)
    ipcRenderer.on("solutions-ready", subscription)
    return () => {
      ipcRenderer.removeListener("solutions-ready", subscription)
    }
  },
  onResetView: (callback: () => void) => {
    const subscription = () => callback()
    ipcRenderer.on("reset-view", subscription)
    return () => {
      ipcRenderer.removeListener("reset-view", subscription)
    }
  },
  onSolutionStart: (callback: () => void) => {
    const subscription = () => callback()
    ipcRenderer.on(PROCESSING_EVENTS.INITIAL_START, subscription)
    return () => {
      ipcRenderer.removeListener(PROCESSING_EVENTS.INITIAL_START, subscription)
    }
  },
  onDebugStart: (callback: () => void) => {
    const subscription = () => callback()
    ipcRenderer.on(PROCESSING_EVENTS.DEBUG_START, subscription)
    return () => {
      ipcRenderer.removeListener(PROCESSING_EVENTS.DEBUG_START, subscription)
    }
  },

  onDebugSuccess: (callback: (data: any) => void) => {
    ipcRenderer.on("debug-success", (_event, data) => callback(data))
    return () => {
      ipcRenderer.removeListener("debug-success", (_event, data) =>
        callback(data)
      )
    }
  },
  onDebugError: (callback: (error: string) => void) => {
    const subscription = (_: any, error: string) => callback(error)
    ipcRenderer.on(PROCESSING_EVENTS.DEBUG_ERROR, subscription)
    return () => {
      ipcRenderer.removeListener(PROCESSING_EVENTS.DEBUG_ERROR, subscription)
    }
  },
  onSolutionError: (callback: (error: string) => void) => {
    const subscription = (_: any, error: string) => callback(error)
    ipcRenderer.on(PROCESSING_EVENTS.INITIAL_SOLUTION_ERROR, subscription)
    return () => {
      ipcRenderer.removeListener(
        PROCESSING_EVENTS.INITIAL_SOLUTION_ERROR,
        subscription
      )
    }
  },
  onProcessingNoScreenshots: (callback: () => void) => {
    const subscription = () => callback()
    ipcRenderer.on(PROCESSING_EVENTS.NO_SCREENSHOTS, subscription)
    return () => {
      ipcRenderer.removeListener(PROCESSING_EVENTS.NO_SCREENSHOTS, subscription)
    }
  },

  onProblemExtracted: (callback: (data: any) => void) => {
    const subscription = (_: any, data: any) => callback(data)
    ipcRenderer.on(PROCESSING_EVENTS.PROBLEM_EXTRACTED, subscription)
    return () => {
      ipcRenderer.removeListener(
        PROCESSING_EVENTS.PROBLEM_EXTRACTED,
        subscription
      )
    }
  },
  onSolutionSuccess: (callback: (data: any) => void) => {
    const subscription = (_: any, data: any) => callback(data)
    ipcRenderer.on(PROCESSING_EVENTS.SOLUTION_SUCCESS, subscription)
    return () => {
      ipcRenderer.removeListener(
        PROCESSING_EVENTS.SOLUTION_SUCCESS,
        subscription
      )
    }
  },
  onUnauthorized: (callback: () => void) => {
    const subscription = () => callback()
    ipcRenderer.on(PROCESSING_EVENTS.UNAUTHORIZED, subscription)
    return () => {
      ipcRenderer.removeListener(PROCESSING_EVENTS.UNAUTHORIZED, subscription)
    }
  },
  moveWindowLeft: () => ipcRenderer.invoke("move-window-left"),
  moveWindowRight: () => ipcRenderer.invoke("move-window-right"),
  moveWindowUp: () => ipcRenderer.invoke("move-window-up"),
  moveWindowDown: () => ipcRenderer.invoke("move-window-down"),
  moveWindowBy: (dx: number, dy: number) => ipcRenderer.invoke("move-window-by", dx, dy),
  toggleWindow: () => ipcRenderer.invoke("toggle-window"),
  analyzeAudioFromBase64: (data: string, mimeType: string) => ipcRenderer.invoke("analyze-audio-base64", data, mimeType),
  analyzeAudioFile: (path: string) => ipcRenderer.invoke("analyze-audio-file", path),
  analyzeImageFile: (path: string) => ipcRenderer.invoke("analyze-image-file", path),
  quitApp: () => ipcRenderer.invoke("quit-app"),
  onAgentReply: (callback: (data: { text: string }) => void) => {
    const subscription = (_: any, data: { text: string }) => callback(data)
    ipcRenderer.on("agent-reply", subscription)
    return () => ipcRenderer.removeListener("agent-reply", subscription)
  },
  setNotificationsEnabled: (enabled: boolean) => ipcRenderer.invoke("set-notifications-enabled", enabled),
  openWidget: (spec: {
    id?: string
    title?: string
    kind: "html" | "markdown" | "text" | "image" | "chart"
    width?: number
    height?: number
    css?: string
    payload: {
      html?: string
      markdown?: string
      text?: string
      imageUrl?: string
      chartConfig?: unknown
    }
  }) => ipcRenderer.invoke("open-widget", spec),
  
  // ─── Session Management ──────────────────────────────
  getSessions: () => ipcRenderer.invoke("get-sessions"),
  getCurrentSession: () => ipcRenderer.invoke("get-current-session"),
  setCurrentSession: (session: {
    id: string
    model: string
    name: string
    metadata?: {
      claude_code_conversation_id?: string
      codex_conversation_id?: string
      codex_cwd?: string
    }
  } | null) =>
    ipcRenderer.invoke("set-current-session", session),
  createSession: (params: {
    id: string
    name: string
    model: string
    metadata?: {
      claude_code_conversation_id?: string
      codex_conversation_id?: string
      codex_cwd?: string
    }
  }) =>
    ipcRenderer.invoke("create-session", params),
  getCodexSessions: () => ipcRenderer.invoke("get-codex-sessions"),
  getClaudeCodeSessions: () => ipcRenderer.invoke("get-claude-code-sessions"),
  sendCodexMessage: (params: { conversationId: string; prompt: string; cwd?: string }) =>
    ipcRenderer.invoke("send-codex-message", params),
  createSessionMessage: (params: {
    sessionId: string
    role: "user" | "assistant"
    content: string
    deviceId?: string
  }) =>
    ipcRenderer.invoke("create-session-message", params),
  getSessionMessages: (sessionId: string, since?: string) =>
    ipcRenderer.invoke("get-session-messages", sessionId, since),
  deleteSession: (sessionId: string) =>
    ipcRenderer.invoke("delete-session", sessionId),
  onSessionMessagesUpdate: (callback: (data: { sessionId: string; messages: any[] }) => void) => {
    const subscription = (_: any, data: { sessionId: string; messages: any[] }) => callback(data)
    ipcRenderer.on("session-messages-update", subscription)
    return () => ipcRenderer.removeListener("session-messages-update", subscription)
  },

  // ─── Network Info & Device Connection ──────────────
  getNetworkInfo: () => ipcRenderer.invoke("get-network-info"),
  connectIpad: (host: string, port?: number) => ipcRenderer.invoke("connect-ipad", host, port),

  // ─── Iris Device Discovery ─────────────────────────
  getIrisDevices: () => ipcRenderer.invoke("get-iris-devices"),
  getIrisDevice: (id: string) => ipcRenderer.invoke("get-iris-device", id),
  getPrimaryIrisDevice: () => ipcRenderer.invoke("get-primary-iris-device"),
  getMacDeviceId: () => ipcRenderer.invoke("get-mac-device-id"),
  onIrisDeviceFound: (callback: (device: any) => void) => {
    const subscription = (_: any, device: any) => callback(device)
    ipcRenderer.on("iris-device-found", subscription)
    return () => ipcRenderer.removeListener("iris-device-found", subscription)
  },
  onIrisDeviceLost: (callback: (deviceId: string) => void) => {
    const subscription = (_: any, deviceId: string) => callback(deviceId)
    ipcRenderer.on("iris-device-lost", subscription)
    return () => ipcRenderer.removeListener("iris-device-lost", subscription)
  },
  onIrisDeviceUpdated: (callback: (device: any) => void) => {
    const subscription = (_: any, device: any) => callback(device)
    ipcRenderer.on("iris-device-updated", subscription)
    return () => ipcRenderer.removeListener("iris-device-updated", subscription)
  },

  invoke: (channel: string, ...args: any[]) => ipcRenderer.invoke(channel, ...args)
} as ElectronAPI)

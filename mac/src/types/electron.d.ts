export interface ElectronAPI {
  updateContentDimensions: (dimensions: {
    width: number
    height: number
  }) => Promise<void>
  getScreenshots: () => Promise<Array<{ path: string; preview: string }>>
  deleteScreenshot: (path: string) => Promise<{ success: boolean; error?: string }>
  onScreenshotTaken: (callback: (data: { path: string; preview: string }) => void) => () => void
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
  getSessions: () => Promise<{ items: any[]; count: number }>
  getCurrentSession: () => Promise<{ id: string; model: string; name: string } | null>
  setCurrentSession: (session: { id: string; model: string; name: string } | null) => Promise<{ success: boolean }>
  createSession: (params: { id: string; name: string; model: string }) => Promise<any>
  getSessionMessages: (sessionId: string, since?: string) => Promise<{ items: any[]; count: number }>
  deleteSession: (sessionId: string) => Promise<{ success: boolean; error?: string }>
  onSessionMessagesUpdate: (callback: (data: { sessionId: string; messages: any[] }) => void) => () => void
  getNetworkInfo: () => Promise<{ macIp: string; allIps: string[]; hostname: string; connectedDevices: any[] }>
  connectIpad: (host: string, port?: number) => Promise<{ success: boolean; error?: string }>
  getIrisDevices: () => Promise<any[]>
  getIrisDevice: (id: string) => Promise<any | null>
  getPrimaryIrisDevice: () => Promise<any | null>
  getMacDeviceId: () => Promise<string>
  onIrisDeviceFound: (callback: (device: any) => void) => () => void
  onIrisDeviceLost: (callback: (deviceId: string) => void) => () => void
  onIrisDeviceUpdated: (callback: (device: any) => void) => () => void
  invoke: (channel: string, ...args: any[]) => Promise<any>
}

declare global {
  interface Window {
    electronAPI: ElectronAPI
  }
} 

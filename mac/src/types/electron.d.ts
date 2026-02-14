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
  analyzeAudioFromBase64: (data: string, mimeType: string) => Promise<{ text: string; timestamp: number }>
  analyzeAudioFile: (path: string) => Promise<{ text: string; timestamp: number }>
  quitApp: () => Promise<void>
  startClaudeChatStream: (requestId: string, message: string) => Promise<{ success: boolean; error?: string }>
  onClaudeChatStreamChunk: (callback: (data: { requestId: string; chunk: string }) => void) => () => void
  onClaudeChatStreamDone: (callback: (data: { requestId: string; text: string }) => void) => () => void
  onClaudeChatStreamError: (callback: (data: { requestId: string; error: string }) => void) => () => void
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
  invoke: (channel: string, ...args: any[]) => Promise<any>
}

declare global {
  interface Window {
    electronAPI: ElectronAPI
  }
} 

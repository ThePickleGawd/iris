// ipcHandlers.ts

import { ipcMain, app, Notification } from "electron"
import { AppState } from "./main"
import { WidgetWindowManager, WidgetSpec } from "./WidgetWindowManager"

export function initializeIpcHandlers(appState: AppState): void {
  let notificationsEnabled = true
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
  ipcMain.handle("analyze-image-file", async (event, path: string) => {
    try {
      const result = await appState.processingHelper.getLLMHelper().analyzeImageFile(path)
      return result
    } catch (error: any) {
      console.error("Error in analyze-image-file handler:", error)
      throw error
    }
  })

  // IPC handler for analyzing image from base64 data
  ipcMain.handle("analyze-image-base64", async (_, data: string, mimeType: string, userPrompt?: string) => {
    try {
      const result = await appState.processingHelper
        .getLLMHelper()
        .analyzeImageFromBase64(data, mimeType, userPrompt)
      return result
    } catch (error: any) {
      console.error("Error in analyze-image-base64 handler:", error)
      throw error
    }
  })

  ipcMain.handle("claude-chat", async (event, message: string) => {
    try {
      const latestScreenshotPath = getLatestScreenshotPathFromQueues()
      const result = await appState
        .processingHelper
        .getLLMHelper()
        .chatWithClaude(message, latestScreenshotPath || undefined);
      notifyAgentReply(result);
      event.sender.send("agent-reply", { text: result });
      return result;
    } catch (error: any) {
      console.error("Error in claude-chat handler:", error);
      throw error;
    }
  });

  ipcMain.handle("claude-chat-stream", async (event, requestId: string, message: string) => {
    try {
      const llm = appState.processingHelper.getLLMHelper();
      const latestScreenshotPath = getLatestScreenshotPathFromQueues()
      const full = await llm.chatWithClaudeStream(
        message,
        latestScreenshotPath || undefined,
        (chunk) => {
        event.sender.send("claude-chat-stream-chunk", { requestId, chunk });
      });
      notifyAgentReply(full);
      event.sender.send("agent-reply", { text: full });
      event.sender.send("claude-chat-stream-done", { requestId, text: full });
      return { success: true };
    } catch (error: any) {
      event.sender.send("claude-chat-stream-error", {
        requestId,
        error: error?.message || String(error)
      });
      return { success: false, error: error?.message || String(error) };
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

  // LLM Model Management Handlers
  ipcMain.handle("get-current-llm-config", async () => {
    try {
      const llmHelper = appState.processingHelper.getLLMHelper();
      return {
        provider: llmHelper.getCurrentProvider(),
        model: llmHelper.getCurrentModel(),
        isOllama: llmHelper.isUsingOllama()
      };
    } catch (error: any) {
      console.error("Error getting current LLM config:", error);
      throw error;
    }
  });

  ipcMain.handle("get-available-ollama-models", async () => {
    try {
      const llmHelper = appState.processingHelper.getLLMHelper();
      const models = await llmHelper.getOllamaModels();
      return models;
    } catch (error: any) {
      console.error("Error getting Ollama models:", error);
      throw error;
    }
  });

  ipcMain.handle("switch-to-ollama", async (_, model?: string, url?: string) => {
    try {
      const llmHelper = appState.processingHelper.getLLMHelper();
      await llmHelper.switchToOllama(model, url);
      return { success: true };
    } catch (error: any) {
      console.error("Error switching to Ollama:", error);
      return { success: false, error: error.message };
    }
  });

  ipcMain.handle("switch-to-claude", async (_, apiKey?: string) => {
    try {
      const llmHelper = appState.processingHelper.getLLMHelper();
      await llmHelper.switchToClaude(apiKey);
      return { success: true };
    } catch (error: any) {
      console.error("Error switching to Claude:", error);
      return { success: false, error: error.message };
    }
  });

  ipcMain.handle("test-llm-connection", async () => {
    try {
      const llmHelper = appState.processingHelper.getLLMHelper();
      const result = await llmHelper.testConnection();
      return result;
    } catch (error: any) {
      console.error("Error testing LLM connection:", error);
      return { success: false, error: error.message };
    }
  });

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

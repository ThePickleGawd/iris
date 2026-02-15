import path from "node:path"
import fs from "node:fs"
import { execFile } from "node:child_process"
import screenshot from "screenshot-desktop"
import sharp from "sharp"
import type { AppState } from "./main"

export class ScreenMonitor {
  private readonly appState: AppState
  private readonly intervalMs: number
  private readonly majorChangeThreshold: number
  private readonly maxStoredMonitorShots: number
  private timer: ReturnType<typeof setInterval> | null = null
  private previousCapturePath: string | null = null
  private isCapturing = false

  constructor(appState: AppState) {
    this.appState = appState
    this.intervalMs = Number(process.env.SCREEN_MONITOR_INTERVAL_MS) || 10_000
    this.majorChangeThreshold = Number(process.env.SCREEN_MONITOR_DIFF_THRESHOLD) || 0.12
    this.maxStoredMonitorShots = Number(process.env.SCREEN_MONITOR_MAX_FILES) || 5_000
  }

  public start(): void {
    if (this.timer) return

    this.captureAndProcess().catch((error) => {
      console.error("[ScreenMonitor] Initial capture failed:", error)
    })

    this.timer = setInterval(() => {
      this.captureAndProcess().catch((error) => {
        console.error("[ScreenMonitor] Capture failed:", error)
      })
    }, this.intervalMs)

    console.log(
      `[ScreenMonitor] Started (interval=${this.intervalMs}ms, threshold=${this.majorChangeThreshold})`
    )
  }

  public stop(): void {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  private async captureAndProcess(): Promise<void> {
    if (this.isCapturing) return
    this.isCapturing = true

    try {
      const monitorDir = this.appState.getScreenshotHelper().getMonitorScreenshotDir()
      const timestamp = new Date().toISOString().replace(/[:.]/g, "-")
      const capturePath = path.join(monitorDir, `screen-${timestamp}.png`)

      await this.captureToFile(capturePath)
      const currentExists = await this.fileExists(capturePath)
      if (!currentExists) {
        console.warn(`[ScreenMonitor] Capture file was not created: ${capturePath}`)
        this.previousCapturePath = null
        return
      }
      console.log(`[ScreenMonitor] Screenshot taken: ${capturePath}`)

      if (this.previousCapturePath) {
        const previousExists = await this.fileExists(this.previousCapturePath)
        if (!previousExists) {
          console.warn(
            `[ScreenMonitor] Previous capture missing, skipping diff: ${this.previousCapturePath}`
          )
          this.previousCapturePath = capturePath
          return
        }

        const diffScore = await this.calculateDiffScore(
          this.previousCapturePath,
          capturePath
        )
        const majorChange = diffScore >= this.majorChangeThreshold
        console.log(
          `[ScreenMonitor] Major change vs previous: ${majorChange} (score=${diffScore.toFixed(3)}, threshold=${this.majorChangeThreshold})`
        )

        if (majorChange) {
          const queuePath = await this.appState.addExistingScreenshotToQueue(
            capturePath,
            "queue"
          )
          const preview = await this.appState.getImagePreview(queuePath)
          const mainWindow = this.appState.getMainWindow()
          if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send("screenshot-taken", {
              path: queuePath,
              preview,
              source: "screen-monitor",
              diffScore
            })
          }

          console.log(
            `[ScreenMonitor] Major change detected (score=${diffScore.toFixed(3)}): ${capturePath}`
          )
        }
      } else {
        console.log("[ScreenMonitor] Major change vs previous: N/A (no previous screenshot)")
      }

      this.previousCapturePath = capturePath
      await this.cleanupOldMonitorScreenshots(monitorDir)
    } catch (error) {
      console.error("[ScreenMonitor] Error while capturing screen:", error)
    } finally {
      this.isCapturing = false
    }
  }

  private async calculateDiffScore(
    previousPath: string,
    currentPath: string
  ): Promise<number> {
    const targetWidth = 320
    const targetHeight = 180

    const [prevBuffer, currBuffer] = await Promise.all([
      sharp(previousPath)
        .resize(targetWidth, targetHeight, { fit: "fill" })
        .grayscale()
        .raw()
        .toBuffer(),
      sharp(currentPath)
        .resize(targetWidth, targetHeight, { fit: "fill" })
        .grayscale()
        .raw()
        .toBuffer()
    ])

    const pixelCount = Math.min(prevBuffer.length, currBuffer.length)
    if (pixelCount === 0) return 0

    let totalAbsoluteDiff = 0
    for (let i = 0; i < pixelCount; i += 1) {
      totalAbsoluteDiff += Math.abs(prevBuffer[i] - currBuffer[i])
    }

    return totalAbsoluteDiff / (pixelCount * 255)
  }

  private async captureToFile(capturePath: string): Promise<void> {
    if (process.platform === "darwin") {
      try {
        await new Promise<void>((resolve, reject) => {
          execFile(
            "/usr/sbin/screencapture",
            ["-x", "-t", "png", capturePath],
            (error) => {
              if (error) {
                reject(error)
                return
              }
              resolve()
            }
          )
        })
        return
      } catch (error) {
        console.warn("[ScreenMonitor] Native screencapture failed, falling back:", error)
      }
    }

    const result = await screenshot()
    if (Buffer.isBuffer(result)) {
      await fs.promises.writeFile(capturePath, result)
      return
    }

    // Fallback for unexpected return types from screenshot providers.
    if (typeof result === "string") {
      await fs.promises.copyFile(result, capturePath)
      return
    }

    throw new Error("Screen capture did not return image data")
  }

  private async fileExists(filePath: string): Promise<boolean> {
    try {
      await fs.promises.access(filePath, fs.constants.F_OK)
      return true
    } catch {
      return false
    }
  }

  private async cleanupOldMonitorScreenshots(monitorDir: string): Promise<void> {
    const files = await fs.promises.readdir(monitorDir)
    if (files.length <= this.maxStoredMonitorShots) return

    const sorted = files
      .filter((name: string) => name.endsWith(".png"))
      .sort((a: string, b: string) => a.localeCompare(b))

    const filesToDelete = sorted.slice(0, Math.max(0, sorted.length - this.maxStoredMonitorShots))
    await Promise.all(
      filesToDelete.map((name: string) =>
        fs.promises
          .unlink(path.join(monitorDir, name))
          .catch((error: unknown) =>
            console.error(`[ScreenMonitor] Failed deleting old monitor screenshot ${name}:`, error)
          )
      )
    )
  }
}

// ScreenshotHelper.ts

import path from "node:path"
import fs from "node:fs"
import { execFile } from "node:child_process"
import { app } from "electron"
import { v4 as uuidv4 } from "uuid"
import screenshot from "screenshot-desktop"
import sharp from "sharp"
import { uploadScreenshotToBackend } from "./backendUploader"

export class ScreenshotHelper {
  private screenshotQueue: string[] = []
  private extraScreenshotQueue: string[] = []
  private readonly MAX_SCREENSHOTS = 5
  private readonly majorChangeThreshold: number
  private previousCapturedPath: string | null = null

  private readonly screenshotDir: string
  private readonly extraScreenshotDir: string
  private readonly monitorScreenshotDir: string

  private view: "queue" | "solutions" = "queue"

  constructor(view: "queue" | "solutions" = "queue") {
    this.view = view
    this.majorChangeThreshold = Number(process.env.SCREENSHOT_DIFF_THRESHOLD) || 0.12

    const backendMacScreenshotDir = path.resolve(process.cwd(), "../backend/data/screenshots/mac")
    const preferredMonitorDir =
      process.env.IRIS_MONITOR_SCREENSHOT_DIR?.trim() || backendMacScreenshotDir

    // Initialize directories
    this.screenshotDir = path.join(app.getPath("userData"), "screenshots")
    this.extraScreenshotDir = path.join(
      app.getPath("userData"),
      "extra_screenshots"
    )
    this.monitorScreenshotDir = preferredMonitorDir

    // Create directories if they don't exist
    if (!fs.existsSync(this.screenshotDir)) {
      fs.mkdirSync(this.screenshotDir, { recursive: true })
    }
    if (!fs.existsSync(this.extraScreenshotDir)) {
      fs.mkdirSync(this.extraScreenshotDir, { recursive: true })
    }
    if (!fs.existsSync(this.monitorScreenshotDir)) {
      fs.mkdirSync(this.monitorScreenshotDir, { recursive: true })
    }
  }

  public getView(): "queue" | "solutions" {
    return this.view
  }

  public setView(view: "queue" | "solutions"): void {
    this.view = view
  }

  public getScreenshotQueue(): string[] {
    return this.screenshotQueue
  }

  public getExtraScreenshotQueue(): string[] {
    return this.extraScreenshotQueue
  }

  public getMonitorScreenshotDir(): string {
    return this.monitorScreenshotDir
  }

  public clearQueues(): void {
    // Clear screenshotQueue
    this.screenshotQueue.forEach((screenshotPath) => {
      fs.unlink(screenshotPath, (err) => {
        if (err)
          console.error(`Error deleting screenshot at ${screenshotPath}:`, err)
      })
    })
    this.screenshotQueue = []

    // Clear extraScreenshotQueue
    this.extraScreenshotQueue.forEach((screenshotPath) => {
      fs.unlink(screenshotPath, (err) => {
        if (err)
          console.error(
            `Error deleting extra screenshot at ${screenshotPath}:`,
            err
          )
      })
    })
    this.extraScreenshotQueue = []
  }

  public async takeScreenshot(
    _hideMainWindow: () => void,
    _showMainWindow: () => void
  ): Promise<string> {
    try {
      let screenshotPath = ""

      if (this.view === "queue") {
        screenshotPath = path.join(this.screenshotDir, `${uuidv4()}.png`)
        await this.captureToFile(screenshotPath)

        this.screenshotQueue.push(screenshotPath)
        if (this.screenshotQueue.length > this.MAX_SCREENSHOTS) {
          const removedPath = this.screenshotQueue.shift()
          if (removedPath) {
            try {
              await fs.promises.unlink(removedPath)
            } catch (error) {
              console.error("Error removing old screenshot:", error)
            }
          }
        }
      } else {
        screenshotPath = path.join(this.extraScreenshotDir, `${uuidv4()}.png`)
        await this.captureToFile(screenshotPath)

        this.extraScreenshotQueue.push(screenshotPath)
        if (this.extraScreenshotQueue.length > this.MAX_SCREENSHOTS) {
          const removedPath = this.extraScreenshotQueue.shift()
          if (removedPath) {
            try {
              await fs.promises.unlink(removedPath)
            } catch (error) {
              console.error("Error removing old screenshot:", error)
            }
          }
        }
      }

      await this.logCaptureWithDiff(screenshotPath, "manual")

      // Upload to Backend for agent access
      uploadScreenshotToBackend(screenshotPath, { source: "manual" }).catch(
        (err) => console.error("[ScreenshotHelper] Backend upload failed:", err)
      )

      return screenshotPath
    } catch (error) {
      console.error("Error taking screenshot:", error)
      throw new Error(`Failed to take screenshot: ${error.message}`)
    }
  }

  public async getImagePreview(filepath: string): Promise<string> {
    try {
      const data = await fs.promises.readFile(filepath)
      return `data:image/png;base64,${data.toString("base64")}`
    } catch (error) {
      console.error("Error reading image:", error)
      throw error
    }
  }

  public async addExistingScreenshotToQueue(
    sourcePath: string,
    view: "queue" | "solutions" = "queue"
  ): Promise<string> {
    const destinationDir = view === "queue" ? this.screenshotDir : this.extraScreenshotDir
    const destinationPath = path.join(destinationDir, `${uuidv4()}.png`)
    await fs.promises.copyFile(sourcePath, destinationPath)

    if (view === "queue") {
      this.screenshotQueue.push(destinationPath)
      if (this.screenshotQueue.length > this.MAX_SCREENSHOTS) {
        const removedPath = this.screenshotQueue.shift()
        if (removedPath) {
          try {
            await fs.promises.unlink(removedPath)
          } catch (error) {
            console.error("Error removing old screenshot:", error)
          }
        }
      }
    } else {
      this.extraScreenshotQueue.push(destinationPath)
      if (this.extraScreenshotQueue.length > this.MAX_SCREENSHOTS) {
        const removedPath = this.extraScreenshotQueue.shift()
        if (removedPath) {
          try {
            await fs.promises.unlink(removedPath)
          } catch (error) {
            console.error("Error removing old extra screenshot:", error)
          }
        }
      }
    }

    await this.logCaptureWithDiff(destinationPath, "imported")
    return destinationPath
  }

  public async deleteScreenshot(
    path: string
  ): Promise<{ success: boolean; error?: string }> {
    try {
      await fs.promises.unlink(path)
      if (this.view === "queue") {
        this.screenshotQueue = this.screenshotQueue.filter(
          (filePath) => filePath !== path
        )
      } else {
        this.extraScreenshotQueue = this.extraScreenshotQueue.filter(
          (filePath) => filePath !== path
        )
      }
      return { success: true }
    } catch (error) {
      console.error("Error deleting file:", error)
      return { success: false, error: error.message }
    }
  }

  private async logCaptureWithDiff(
    currentPath: string,
    source: "manual" | "imported"
  ): Promise<void> {
    let majorChange = false
    let diffScore: number | null = null

    if (this.previousCapturedPath) {
      const previousExists = await this.fileExists(this.previousCapturedPath)
      const currentExists = await this.fileExists(currentPath)
      if (previousExists && currentExists) {
        diffScore = await this.calculateDiffScore(this.previousCapturedPath, currentPath)
        majorChange = diffScore >= this.majorChangeThreshold
      }
    }

    console.log(
      `[ScreenshotHelper] Screenshot taken (source=${source}, view=${this.view}, path=${currentPath})`
    )
    if (diffScore === null) {
      console.log("[ScreenshotHelper] Major change vs previous: N/A (no previous screenshot)")
    } else {
      console.log(
        `[ScreenshotHelper] Major change vs previous: ${majorChange} (score=${diffScore.toFixed(3)}, threshold=${this.majorChangeThreshold})`
      )
    }

    this.previousCapturedPath = currentPath
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

  private async fileExists(filePath: string): Promise<boolean> {
    try {
      await fs.promises.access(filePath, fs.constants.F_OK)
      return true
    } catch {
      return false
    }
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
        console.warn("[ScreenshotHelper] Native screencapture failed, falling back:", error)
      }
    }

    await screenshot({ filename: capturePath })
  }
}

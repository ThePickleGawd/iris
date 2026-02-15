import fs from "node:fs"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { uploadScreenshotToBackend } from "./backendUploader"

const AGENT_SERVER_URL = process.env.IRIS_AGENT_URL || "http://localhost:8000"
const DEFAULT_MODEL = process.env.IRIS_MODEL || "gpt-5.2-mini"
const AGENT_CHAT_PATH = "/v1/agent"

interface ChatEnvelope {
  protocol_version: "1.0"
  kind: "agent.request"
  request_id: string
  timestamp: string
  workspace_id: string
  session_id: string
  input: {
    type: "text"
    text: string
  }
  context: {
    recent_messages: Array<{ role: "user" | "assistant"; text: string }>
  }
  model: string
  metadata: {
    model: string
    agent: string
  }
}

export class LLMHelper {
  private readonly agentServerUrl: string
  private readonly modelName: string
  private readonly namespace: string

  constructor() {
    this.agentServerUrl = AGENT_SERVER_URL
    this.modelName = DEFAULT_MODEL
    this.namespace = `mac-helper-${process.pid}`
    console.log(`[LLMHelper] Backend-only mode enabled (${this.agentServerUrl})`)
  }

  private cleanJsonResponse(text: string): string {
    return text.replace(/^```(?:json)?\n/, "").replace(/\n```$/, "").trim()
  }

  private parseJsonSafely<T>(text: string, fallback: T): T {
    const cleaned = this.cleanJsonResponse(text)
    try {
      return JSON.parse(cleaned) as T
    } catch {
      const firstBrace = cleaned.indexOf("{")
      const lastBrace = cleaned.lastIndexOf("}")
      if (firstBrace !== -1 && lastBrace > firstBrace) {
        try {
          return JSON.parse(cleaned.slice(firstBrace, lastBrace + 1)) as T
        } catch {
          return fallback
        }
      }
      return fallback
    }
  }

  private postJson(pathname: string, body: unknown, timeoutMs = 120_000): Promise<any> {
    return new Promise((resolve, reject) => {
      const serialized = JSON.stringify(body)
      const parsed = new URL(`${this.agentServerUrl}${pathname}`)
      const req = http.request(
        {
          hostname: parsed.hostname,
          port: parsed.port,
          path: parsed.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(serialized)
          },
          timeout: timeoutMs
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
              reject(new Error(`Agent server error ${res.statusCode}: ${data.slice(0, 500)}`))
            }
          })
        }
      )
      req.on("error", reject)
      req.on("timeout", () => {
        req.destroy()
        reject(new Error("Agent server timeout"))
      })
      req.write(serialized)
      req.end()
    })
  }

  private async agentChat(message: string, chatId: string): Promise<string> {
    const payload: ChatEnvelope = {
      protocol_version: "1.0",
      kind: "agent.request",
      request_id: `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
      timestamp: new Date().toISOString(),
      workspace_id: chatId,
      session_id: chatId,
      input: {
        type: "text",
        text: message
      },
      context: {
        recent_messages: []
      },
      model: this.modelName,
      metadata: {
        model: this.modelName,
        agent: this.modelName
      }
    }
    const response = await this.postJson(AGENT_CHAT_PATH, payload, 120_000)
    const text = typeof response?.text === "string" ? response.text : ""
    if (!text) {
      throw new Error("Agent server returned no text")
    }
    return text
  }

  private async uploadScreenshotIfPresent(imagePath: string, chatId: string, source: string) {
    await uploadScreenshotToBackend(imagePath, {
      deviceId: "mac",
      sessionId: chatId,
      source
    }).catch(() => {})
  }

  private async writeBase64ImageToTempFile(data: string, mimeType: string): Promise<string> {
    const ext =
      mimeType === "image/jpeg"
        ? "jpg"
        : mimeType === "image/webp"
          ? "webp"
          : mimeType === "image/gif"
            ? "gif"
            : "png"
    const filePath = path.join(
      os.tmpdir(),
      `iris-base64-${Date.now()}-${Math.random().toString(16).slice(2)}.${ext}`
    )
    await fs.promises.writeFile(filePath, Buffer.from(data, "base64"))
    return filePath
  }

  public async extractProblemFromImages(imagePaths: string[]) {
    const chatId = `${this.namespace}-extract`
    for (const imagePath of imagePaths) {
      await this.uploadScreenshotIfPresent(imagePath, chatId, "extract-problem")
    }
    const text = await this.agentChat(
      "Use read_screenshot(device='mac') to inspect the latest screenshot for this session. Return strict JSON with keys: problem_statement, context, suggested_responses (array), reasoning.",
      chatId
    )
    return this.parseJsonSafely(text, {
      problem_statement: text,
      context: "",
      suggested_responses: [],
      reasoning: ""
    })
  }

  public async generateSolution(problemInfo: any) {
    const chatId = `${this.namespace}-solution`
    const text = await this.agentChat(
      `Given this problem context, return strict JSON in shape {"solution":{"code":"","problem_statement":"","context":"","suggested_responses":[],"reasoning":""}}:\n${JSON.stringify(problemInfo, null, 2)}`,
      chatId
    )
    return this.parseJsonSafely(text, {
      solution: {
        code: text,
        problem_statement: String(problemInfo?.problem_statement || ""),
        context: "",
        suggested_responses: [],
        reasoning: ""
      }
    })
  }

  public async debugSolutionWithImages(problemInfo: any, currentCode: string, debugImagePaths: string[]) {
    const chatId = `${this.namespace}-debug`
    for (const imagePath of debugImagePaths) {
      await this.uploadScreenshotIfPresent(imagePath, chatId, "debug-screenshot")
    }
    const text = await this.agentChat(
      `Use read_screenshot(device='mac') for the latest debug image and return strict JSON in shape {"solution":{"code":"","problem_statement":"","context":"","suggested_responses":[],"reasoning":""}}.\nProblem:\n${JSON.stringify(problemInfo, null, 2)}\nCurrent code:\n${currentCode}`,
      chatId
    )
    return this.parseJsonSafely(text, {
      solution: {
        code: currentCode,
        problem_statement: String(problemInfo?.problem_statement || ""),
        context: "",
        suggested_responses: [],
        reasoning: text
      }
    })
  }

  public async analyzeAudioFile(_audioPath: string) {
    const chatId = `${this.namespace}-audio`
    const text = await this.agentChat(
      "User provided audio context in the desktop app. Provide concise next steps and suggestions.",
      chatId
    )
    return { text, timestamp: Date.now() }
  }

  public async analyzeAudioFromBase64(_data: string, _mimeType: string) {
    const chatId = `${this.namespace}-audio-base64`
    const text = await this.agentChat(
      "User provided inline audio context in the desktop app. Provide concise next steps and suggestions.",
      chatId
    )
    return { text, timestamp: Date.now() }
  }

  public async analyzeImageFile(imagePath: string) {
    const chatId = `${this.namespace}-image`
    await this.uploadScreenshotIfPresent(imagePath, chatId, "image-analysis")
    const text = await this.agentChat(
      "Use read_screenshot(device='mac') to inspect the latest uploaded screenshot for this session and give a concise analysis with next actions.",
      chatId
    )
    return { text, timestamp: Date.now() }
  }

  public async analyzeImageFromBase64(data: string, mimeType: string, userPrompt?: string) {
    let tempPath: string | null = null
    try {
      tempPath = await this.writeBase64ImageToTempFile(data, mimeType || "image/png")
      const chatId = `${this.namespace}-image-base64`
      await this.uploadScreenshotIfPresent(tempPath, chatId, "image-analysis-inline")
      const prompt =
        userPrompt && userPrompt.trim()
          ? `Use read_screenshot(device='mac') to inspect the latest uploaded screenshot and answer this request: "${userPrompt.trim()}".`
          : "Use read_screenshot(device='mac') to inspect the latest uploaded screenshot and provide a concise analysis."
      const text = await this.agentChat(prompt, chatId)
      return { text, timestamp: Date.now() }
    } finally {
      if (tempPath) {
        fs.promises.unlink(tempPath).catch(() => {})
      }
    }
  }

  public async chatWithClaude(message: string, latestScreenshotPath?: string): Promise<string> {
    const chatId = `${this.namespace}-chat`
    if (latestScreenshotPath) {
      await this.uploadScreenshotIfPresent(latestScreenshotPath, chatId, "chat-context")
    }
    return this.agentChat(message, chatId)
  }

  public async chatWithClaudeStream(
    message: string,
    latestScreenshotPath: string | undefined,
    onChunk: (chunk: string) => void
  ): Promise<string> {
    const text = await this.chatWithClaude(message, latestScreenshotPath)
    onChunk(text)
    return text
  }

  public async chat(message: string): Promise<string> {
    return this.chatWithClaude(message)
  }

  public async testConnection(): Promise<{ success: boolean; error?: string }> {
    try {
      const parsed = new URL(`${this.agentServerUrl}/health`)
      await new Promise<void>((resolve, reject) => {
        const req = http.request(
          {
            hostname: parsed.hostname,
            port: parsed.port,
            path: parsed.pathname,
            method: "GET",
            timeout: 10_000
          },
          (res) => {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              resolve()
            } else {
              reject(new Error(`Health check failed (${res.statusCode})`))
            }
          }
        )
        req.on("error", reject)
        req.on("timeout", () => {
          req.destroy()
          reject(new Error("Agent server timeout"))
        })
        req.end()
      })
      return { success: true }
    } catch (error: any) {
      return { success: false, error: error?.message || String(error) }
    }
  }
}

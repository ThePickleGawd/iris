import fs from "fs"
import path from "path"

interface OllamaResponse {
  response: string
  done: boolean
}

type ClaudeContentBlock =
  | { type: "text"; text: string }
  | {
      type: "image"
      source: {
        type: "base64"
        media_type: string
        data: string
      }
    }

export class LLMHelper {
  private apiKey: string | null = null
  private claudeModel: string = process.env.CLAUDE_MODEL || "claude-sonnet-4-5"
  private readonly anthropicUrl = "https://api.anthropic.com/v1/messages"
  private useOllama: boolean = false
  private ollamaModel: string = "llama3.2"
  private ollamaUrl: string = "http://localhost:11434"

  constructor(apiKey?: string, useOllama: boolean = false, ollamaModel?: string, ollamaUrl?: string) {
    this.useOllama = useOllama

    if (useOllama) {
      this.ollamaUrl = ollamaUrl || "http://localhost:11434"
      this.ollamaModel = ollamaModel || "gemma:latest"
      console.log(`[LLMHelper] Using Ollama with model: ${this.ollamaModel}`)
      this.initializeOllamaModel()
    } else if (apiKey) {
      this.apiKey = apiKey
      console.log(`[LLMHelper] Using Claude model: ${this.claudeModel}`)
    } else {
      throw new Error("Either provide a Claude API key or enable Ollama mode")
    }
  }

  private cleanJsonResponse(text: string): string {
    return text.replace(/^```(?:json)?\n/, "").replace(/\n```$/, "").trim()
  }

  private getMimeTypeFromPath(filePath: string): string {
    const ext = path.extname(filePath).toLowerCase()
    if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg"
    if (ext === ".webp") return "image/webp"
    if (ext === ".gif") return "image/gif"
    return "image/png"
  }

  private async fileToClaudeImagePart(imagePath: string): Promise<ClaudeContentBlock> {
    const imageData = await fs.promises.readFile(imagePath)
    return {
      type: "image",
      source: {
        type: "base64",
        media_type: this.getMimeTypeFromPath(imagePath),
        data: imageData.toString("base64")
      }
    }
  }

  private async callClaude(content: ClaudeContentBlock[]): Promise<string> {
    if (!this.apiKey) {
      throw new Error("Claude API key is not configured")
    }

    const response = await fetch(this.anthropicUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.apiKey,
        "anthropic-version": "2023-06-01"
      },
      body: JSON.stringify({
        model: this.claudeModel,
        max_tokens: 2000,
        messages: [{ role: "user", content }]
      })
    })

    if (!response.ok) {
      const body = await response.text()
      throw new Error(`Claude API error: ${response.status} ${response.statusText} - ${body}`)
    }

    const data = await response.json()
    const text = (data.content || [])
      .filter((block: any) => block.type === "text")
      .map((block: any) => block.text)
      .join("\n")

    if (!text) {
      throw new Error("Empty response from Claude")
    }

    return text
  }

  private async callClaudeStream(
    content: ClaudeContentBlock[],
    onChunk: (chunk: string) => void
  ): Promise<string> {
    if (!this.apiKey) {
      throw new Error("Claude API key is not configured")
    }

    const response = await fetch(this.anthropicUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.apiKey,
        "anthropic-version": "2023-06-01"
      },
      body: JSON.stringify({
        model: this.claudeModel,
        max_tokens: 2000,
        stream: true,
        messages: [{ role: "user", content }]
      })
    })

    if (!response.ok) {
      const body = await response.text()
      throw new Error(`Claude API error: ${response.status} ${response.statusText} - ${body}`)
    }

    if (!response.body) {
      throw new Error("Claude API stream body is empty")
    }

    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    let fullText = ""

    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split("\n")
      buffer = lines.pop() || ""

      for (const line of lines) {
        const trimmed = line.trim()
        if (!trimmed.startsWith("data:")) continue
        const payload = trimmed.slice(5).trim()
        if (!payload || payload === "[DONE]") continue

        try {
          const parsed = JSON.parse(payload)
          if (parsed.type === "content_block_delta" && parsed.delta?.text) {
            const chunk = parsed.delta.text as string
            fullText += chunk
            onChunk(chunk)
          }
        } catch {
          // Ignore malformed stream lines
        }
      }
    }

    if (!fullText.trim()) {
      throw new Error("Empty response from Claude stream")
    }

    return fullText
  }

  private async callClaudeText(prompt: string): Promise<string> {
    return this.callClaude([{ type: "text", text: prompt }])
  }

  private async buildChatClaudeContent(
    message: string,
    latestScreenshotPath?: string
  ): Promise<ClaudeContentBlock[]> {
    if (!latestScreenshotPath) {
      return [{ type: "text", text: message }]
    }

    try {
      await fs.promises.access(latestScreenshotPath, fs.constants.F_OK)
      return [
        {
          type: "text",
          text:
            "Use the attached latest screenshot as additional context when relevant. " +
            "If the screenshot is not relevant, answer based on the user message only.\n\n" +
            `User message:\n${message}`
        },
        await this.fileToClaudeImagePart(latestScreenshotPath)
      ]
    } catch {
      return [{ type: "text", text: message }]
    }
  }

  private async callOllama(prompt: string): Promise<string> {
    try {
      const response = await fetch(`${this.ollamaUrl}/api/generate`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          model: this.ollamaModel,
          prompt,
          stream: false,
          options: {
            temperature: 0.7,
            top_p: 0.9
          }
        })
      })

      if (!response.ok) {
        throw new Error(`Ollama API error: ${response.status} ${response.statusText}`)
      }

      const data: OllamaResponse = await response.json()
      return data.response
    } catch (error: any) {
      console.error("[LLMHelper] Error calling Ollama:", error)
      throw new Error(`Failed to connect to Ollama: ${error.message}. Make sure Ollama is running on ${this.ollamaUrl}`)
    }
  }

  private async checkOllamaAvailable(): Promise<boolean> {
    try {
      const response = await fetch(`${this.ollamaUrl}/api/tags`)
      return response.ok
    } catch {
      return false
    }
  }

  private async initializeOllamaModel(): Promise<void> {
    try {
      const availableModels = await this.getOllamaModels()
      if (availableModels.length === 0) {
        console.warn("[LLMHelper] No Ollama models found")
        return
      }

      if (!availableModels.includes(this.ollamaModel)) {
        this.ollamaModel = availableModels[0]
        console.log(`[LLMHelper] Auto-selected first available model: ${this.ollamaModel}`)
      }

      await this.callOllama("Hello")
      console.log(`[LLMHelper] Successfully initialized with model: ${this.ollamaModel}`)
    } catch (error: any) {
      console.error(`[LLMHelper] Failed to initialize Ollama model: ${error.message}`)
      try {
        const models = await this.getOllamaModels()
        if (models.length > 0) {
          this.ollamaModel = models[0]
          console.log(`[LLMHelper] Fallback to: ${this.ollamaModel}`)
        }
      } catch (fallbackError: any) {
        console.error(`[LLMHelper] Fallback also failed: ${fallbackError.message}`)
      }
    }
  }

  public async extractProblemFromImages(imagePaths: string[]) {
    try {
      const imageParts = await Promise.all(imagePaths.map((p) => this.fileToClaudeImagePart(p)))
      const prompt = `You are Iris. Please analyze these images and extract the following information in JSON format:\n{\n  "problem_statement": "A clear statement of the problem or situation depicted in the images.",\n  "context": "Relevant background or context from the images.",\n  "suggested_responses": ["First possible answer or action", "Second possible answer or action", "..."],\n  "reasoning": "Explanation of why these suggestions are appropriate."\n}\nImportant: Return ONLY the JSON object, without any markdown formatting or code blocks.`
      const text = this.useOllama
        ? await this.callOllama(prompt)
        : await this.callClaude([{ type: "text", text: prompt }, ...imageParts])
      return JSON.parse(this.cleanJsonResponse(text))
    } catch (error) {
      console.error("Error extracting problem from images:", error)
      throw error
    }
  }

  public async generateSolution(problemInfo: any) {
    const prompt = `You are Iris.\n\nGiven this problem or situation:\n${JSON.stringify(problemInfo, null, 2)}\n\nPlease provide your response in the following JSON format:\n{\n  "solution": {\n    "code": "The code or main answer here.",\n    "problem_statement": "Restate the problem or situation.",\n    "context": "Relevant background/context.",\n    "suggested_responses": ["First possible answer or action", "Second possible answer or action", "..."],\n    "reasoning": "Explanation of why these suggestions are appropriate."\n  }\n}\nImportant: Return ONLY the JSON object, without any markdown formatting or code blocks.`

    try {
      const text = this.useOllama ? await this.callOllama(prompt) : await this.callClaudeText(prompt)
      return JSON.parse(this.cleanJsonResponse(text))
    } catch (error) {
      console.error("[LLMHelper] Error in generateSolution:", error)
      throw error
    }
  }

  public async debugSolutionWithImages(problemInfo: any, currentCode: string, debugImagePaths: string[]) {
    try {
      const imageParts = await Promise.all(debugImagePaths.map((p) => this.fileToClaudeImagePart(p)))
      const prompt = `You are Iris.\n\nGiven:\n1. The original problem or situation: ${JSON.stringify(problemInfo, null, 2)}\n2. The current response or approach: ${currentCode}\n3. The debug information in the provided images\n\nPlease analyze the debug information and provide feedback in this JSON format:\n{\n  "solution": {\n    "code": "The code or main answer here.",\n    "problem_statement": "Restate the problem or situation.",\n    "context": "Relevant background/context.",\n    "suggested_responses": ["First possible answer or action", "Second possible answer or action", "..."],\n    "reasoning": "Explanation of why these suggestions are appropriate."\n  }\n}\nImportant: Return ONLY the JSON object, without any markdown formatting or code blocks.`

      const text = this.useOllama
        ? await this.callOllama(prompt)
        : await this.callClaude([{ type: "text", text: prompt }, ...imageParts])
      return JSON.parse(this.cleanJsonResponse(text))
    } catch (error) {
      console.error("Error debugging solution with images:", error)
      throw error
    }
  }

  public async analyzeAudioFile(_audioPath: string) {
    if (this.useOllama) {
      const text = await this.callOllama("User provided an audio file. Give concise suggested next actions.")
      return { text, timestamp: Date.now() }
    }

    return {
      text: "Audio analysis is not enabled for Claude in this build. Use screenshot/chat input or Ollama mode for local processing.",
      timestamp: Date.now()
    }
  }

  public async analyzeAudioFromBase64(_data: string, _mimeType: string) {
    if (this.useOllama) {
      const text = await this.callOllama("User provided base64 audio. Give concise suggested next actions.")
      return { text, timestamp: Date.now() }
    }

    return {
      text: "Audio analysis is not enabled for Claude in this build. Use screenshot/chat input or Ollama mode for local processing.",
      timestamp: Date.now()
    }
  }

  public async analyzeImageFile(imagePath: string) {
    try {
      const prompt = `You are Iris.\n\nDescribe the content of this image in a short, concise answer. In addition to your main answer, suggest several possible actions or responses the user could take next based on the image. Do not return a structured JSON object, just answer naturally as you would to a user. Be concise and brief.`

      const text = this.useOllama
        ? await this.callOllama(prompt)
        : await this.callClaude([{ type: "text", text: prompt }, await this.fileToClaudeImagePart(imagePath)])

      return { text, timestamp: Date.now() }
    } catch (error) {
      console.error("Error analyzing image file:", error)
      throw error
    }
  }

  public async analyzeImageFromBase64(data: string, mimeType: string, userPrompt?: string) {
    try {
      const prompt =
        userPrompt && userPrompt.trim()
          ? `You are Iris.\n\nThe user shared an image and asked:\n"${userPrompt.trim()}"\n\nRespond directly to the user's request using the image context. Keep it concise and helpful.`
          : `You are Iris.\n\nDescribe the content of this image in a short, concise answer. In addition to your main answer, suggest several possible actions or responses the user could take next based on the image. Do not return a structured JSON object, just answer naturally as you would to a user. Be concise and brief.`

      const text = this.useOllama
        ? await this.callOllama(prompt)
        : await this.callClaude([
            { type: "text", text: prompt },
            {
              type: "image",
              source: {
                type: "base64",
                media_type: mimeType || "image/png",
                data
              }
            }
          ])

      return { text, timestamp: Date.now() }
    } catch (error) {
      console.error("Error analyzing base64 image:", error)
      throw error
    }
  }

  public async chatWithClaude(
    message: string,
    latestScreenshotPath?: string
  ): Promise<string> {
    try {
      if (/(who are you|what(?:'s| is) your name|what are you called|who am i talking to|your name)/i.test(message)) {
        return "I'm Iris."
      }
      if (this.useOllama) {
        const prompt = latestScreenshotPath
          ? `Latest screenshot path: ${latestScreenshotPath}\n\nUser message:\n${message}`
          : message
        return this.callOllama(prompt)
      }
      const content = await this.buildChatClaudeContent(message, latestScreenshotPath)
      return this.callClaude(content)
    } catch (error) {
      console.error("[LLMHelper] Error in chatWithClaude:", error)
      throw error
    }
  }

  public async chatWithClaudeStream(
    message: string,
    latestScreenshotPath: string | undefined,
    onChunk: (chunk: string) => void
  ): Promise<string> {
    try {
      if (/(who are you|what(?:'s| is) your name|what are you called|who am i talking to|your name)/i.test(message)) {
        const text = "I'm Iris."
        onChunk(text)
        return text
      }

      if (this.useOllama) {
        const prompt = latestScreenshotPath
          ? `Latest screenshot path: ${latestScreenshotPath}\n\nUser message:\n${message}`
          : message
        const text = await this.callOllama(prompt)
        onChunk(text)
        return text
      }

      const content = await this.buildChatClaudeContent(message, latestScreenshotPath)
      return this.callClaudeStream(content, onChunk)
    } catch (error) {
      console.error("[LLMHelper] Error in chatWithClaudeStream:", error)
      throw error
    }
  }

  public async chat(message: string): Promise<string> {
    return this.chatWithClaude(message)
  }

  public isUsingOllama(): boolean {
    return this.useOllama
  }

  public async getOllamaModels(): Promise<string[]> {
    if (!this.useOllama) return []

    try {
      const response = await fetch(`${this.ollamaUrl}/api/tags`)
      if (!response.ok) throw new Error("Failed to fetch models")

      const data = await response.json()
      return data.models?.map((model: any) => model.name) || []
    } catch (error) {
      console.error("[LLMHelper] Error fetching Ollama models:", error)
      return []
    }
  }

  public getCurrentProvider(): "ollama" | "claude" {
    return this.useOllama ? "ollama" : "claude"
  }

  public getCurrentModel(): string {
    return this.useOllama ? this.ollamaModel : this.claudeModel
  }

  public async switchToOllama(model?: string, url?: string): Promise<void> {
    this.useOllama = true
    if (url) this.ollamaUrl = url

    if (model) {
      this.ollamaModel = model
    } else {
      await this.initializeOllamaModel()
    }

    console.log(`[LLMHelper] Switched to Ollama: ${this.ollamaModel} at ${this.ollamaUrl}`)
  }

  public async switchToClaude(apiKey?: string): Promise<void> {
    if (apiKey) {
      this.apiKey = apiKey
    }

    if (!this.apiKey) {
      throw new Error("No Claude API key provided and no existing key configured")
    }

    this.useOllama = false
    console.log(`[LLMHelper] Switched to Claude (${this.claudeModel})`)
  }

  public async testConnection(): Promise<{ success: boolean; error?: string }> {
    try {
      if (this.useOllama) {
        const available = await this.checkOllamaAvailable()
        if (!available) {
          return { success: false, error: `Ollama not available at ${this.ollamaUrl}` }
        }
        await this.callOllama("Hello")
        return { success: true }
      }

      const text = await this.callClaudeText("Hello")
      if (!text) {
        return { success: false, error: "Empty response from Claude" }
      }
      return { success: true }
    } catch (error: any) {
      return { success: false, error: error.message }
    }
  }
}

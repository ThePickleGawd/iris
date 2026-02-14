import fs from "node:fs"
import path from "node:path"
import http from "node:http"

const BACKEND_URL = process.env.IRIS_BACKEND_URL || "http://localhost:5000"

/**
 * Upload a screenshot file to the Backend's /api/screenshots endpoint
 * using multipart/form-data over Node's built-in http module.
 */
export async function uploadScreenshotToBackend(
  filePath: string,
  opts: {
    deviceId?: string
    sessionId?: string
    source?: string
  } = {}
): Promise<{ id: string } | null> {
  try {
    await fs.promises.access(filePath, fs.constants.F_OK)
  } catch {
    console.warn("[backendUploader] File does not exist:", filePath)
    return null
  }

  const fileBuffer = await fs.promises.readFile(filePath)
  const fileName = path.basename(filePath)
  const boundary = `----IrisBoundary${Date.now()}`

  // Build multipart body
  const parts: Buffer[] = []

  // File part
  parts.push(Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="screenshot"; filename="${fileName}"\r\nContent-Type: image/png\r\n\r\n`
  ))
  parts.push(fileBuffer)
  parts.push(Buffer.from("\r\n"))

  // Text fields
  const fields: Record<string, string> = {}
  if (opts.deviceId) fields.device_id = opts.deviceId
  if (opts.sessionId) fields.session_id = opts.sessionId
  if (opts.source) fields.source = opts.source
  fields.captured_at = new Date().toISOString()

  for (const [key, value] of Object.entries(fields)) {
    parts.push(Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${value}\r\n`
    ))
  }

  parts.push(Buffer.from(`--${boundary}--\r\n`))
  const body = Buffer.concat(parts)

  const parsed = new URL(`${BACKEND_URL}/api/screenshots`)

  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path: parsed.pathname,
        method: "POST",
        headers: {
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": body.length,
        },
        timeout: 10_000,
      },
      (res) => {
        let data = ""
        res.on("data", (chunk) => (data += chunk))
        res.on("end", () => {
          if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
            try {
              const json = JSON.parse(data)
              console.log(`[backendUploader] Uploaded ${fileName} → id=${json.id}`)
              resolve({ id: json.id })
            } catch {
              resolve(null)
            }
          } else {
            console.warn(`[backendUploader] Upload failed: ${res.statusCode} ${data.slice(0, 200)}`)
            resolve(null)
          }
        })
      }
    )

    req.on("error", (err) => {
      console.warn("[backendUploader] Upload error:", err.message)
      resolve(null) // Don't reject — upload failure shouldn't crash the app
    })
    req.on("timeout", () => {
      req.destroy()
      console.warn("[backendUploader] Upload timed out")
      resolve(null)
    })

    req.write(body)
    req.end()
  })
}

import { Bonjour, type Service } from "bonjour-service"
import { EventEmitter } from "events"
import http from "http"
import os from "os"

export interface IrisDevice {
  id: string
  name: string
  model: string
  system: string
  host: string
  port: number
  addresses: string[]
  linked: boolean
  lastSeen: number
}

/**
 * Discovers Iris Canvas instances on the local network via Bonjour
 * and auto-links with them so both devices know about each other.
 *
 * Events:
 *   "device-found"   (device: IrisDevice)
 *   "device-lost"    (deviceId: string)
 *   "device-updated" (device: IrisDevice)
 */
export class DeviceDiscovery extends EventEmitter {
  private bonjour: Bonjour | null = null
  private browser: any = null
  private devices: Map<string, IrisDevice> = new Map()
  private macDeviceId: string
  private refreshTimer: ReturnType<typeof setInterval> | null = null

  constructor() {
    super()
    this.macDeviceId = this.getOrCreateDeviceId()
  }

  /** Start browsing for _iris-canvas._tcp services */
  start(): void {
    if (this.bonjour) return

    this.bonjour = new Bonjour()

    this.browser = this.bonjour.find({ type: "iris-canvas" }, (service: Service) => {
      this.handleServiceFound(service)
    })

    // Periodically re-check device health
    this.refreshTimer = setInterval(() => this.pruneStaleDevices(), 15_000)

    console.log("[iris-discovery] Browsing for _iris-canvas._tcp services...")
  }

  /** Stop browsing */
  stop(): void {
    if (this.browser) {
      this.browser.stop()
      this.browser = null
    }
    if (this.bonjour) {
      this.bonjour.destroy()
      this.bonjour = null
    }
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = null
    }
    this.devices.clear()
  }

  /** Get all currently known devices */
  getDevices(): IrisDevice[] {
    return Array.from(this.devices.values())
  }

  /** Get a specific device by ID */
  getDevice(id: string): IrisDevice | undefined {
    return this.devices.get(id)
  }

  /** Get the first available device (convenience for single-iPad setups) */
  getPrimaryDevice(): IrisDevice | undefined {
    return this.devices.values().next().value
  }

  /** The Mac's own device ID */
  getDeviceId(): string {
    return this.macDeviceId
  }

  // ─── Internal ──────────────────────────────────────────────

  private async handleServiceFound(service: Service): Promise<void> {
    const addresses = (service.addresses || []).filter(
      (addr: string) => !addr.includes(":") // skip IPv6
    )
    if (addresses.length === 0) {
      console.log("[iris-discovery] Service found but no IPv4 address:", service.name)
      return
    }

    const host = addresses[0]
    const port = service.port

    console.log(`[iris-discovery] Found: ${service.name} at ${host}:${port}`)

    // Probe the device info endpoint
    try {
      const deviceInfo = await this.fetchJSON<{
        id: string
        name: string
        model: string
        system: string
        port: number
      }>(`http://${host}:${port}/api/v1/device`)

      const device: IrisDevice = {
        id: deviceInfo.id,
        name: deviceInfo.name,
        model: deviceInfo.model,
        system: deviceInfo.system,
        host,
        port,
        addresses,
        linked: false,
        lastSeen: Date.now()
      }

      const existing = this.devices.get(device.id)
      this.devices.set(device.id, device)

      if (!existing) {
        console.log(`[iris-discovery] New device: ${device.name} (${device.model})`)
        this.emit("device-found", device)
      } else {
        this.emit("device-updated", device)
      }

      // Auto-link: register this Mac with the iPad
      await this.linkWithDevice(device)
    } catch (err) {
      console.log(`[iris-discovery] Failed to probe ${host}:${port}:`, err)
    }
  }

  private async linkWithDevice(device: IrisDevice): Promise<void> {
    try {
      const hostname = os.hostname()
      const payload = {
        id: this.macDeviceId,
        name: hostname.replace(/\.local$/, ""),
        platform: "macOS",
        port: 0 // Mac doesn't run a server (yet)
      }

      const result = await this.fetchJSON<{ linked: boolean; device: any }>(
        `http://${device.host}:${device.port}/api/v1/link`,
        {
          method: "POST",
          body: JSON.stringify(payload)
        }
      )

      if (result.linked) {
        device.linked = true
        this.devices.set(device.id, device)
        console.log(`[iris-discovery] Linked with ${device.name}`)
        this.emit("device-updated", device)
      }
    } catch (err) {
      console.log(`[iris-discovery] Failed to link with ${device.name}:`, err)
    }
  }

  private pruneStaleDevices(): void {
    const now = Date.now()
    const staleThreshold = 60_000 // 1 minute

    for (const [id, device] of this.devices) {
      if (now - device.lastSeen > staleThreshold) {
        // Try a health check before removing
        this.healthCheck(device).then((alive) => {
          if (alive) {
            device.lastSeen = Date.now()
            this.devices.set(id, device)
          } else {
            this.devices.delete(id)
            console.log(`[iris-discovery] Device lost: ${device.name}`)
            this.emit("device-lost", id)
          }
        })
      }
    }
  }

  private async healthCheck(device: IrisDevice): Promise<boolean> {
    try {
      const data = await this.fetchJSON<{ status: string }>(
        `http://${device.host}:${device.port}/api/v1/health`
      )
      return data.status === "ok"
    } catch {
      return false
    }
  }

  private getOrCreateDeviceId(): string {
    // Use a file-based approach since Electron main process doesn't have localStorage
    const path = require("path")
    const fs = require("fs")
    const configDir = path.join(
      process.env.HOME || process.env.USERPROFILE || "/tmp",
      ".iris"
    )
    const idFile = path.join(configDir, "device-id")

    try {
      return fs.readFileSync(idFile, "utf-8").trim()
    } catch {
      const id = `mac-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
      try {
        fs.mkdirSync(configDir, { recursive: true })
        fs.writeFileSync(idFile, id)
      } catch {
        // If we can't write, just use ephemeral ID
      }
      return id
    }
  }

  private fetchJSON<T>(url: string, options?: { method?: string; body?: string }): Promise<T> {
    return new Promise((resolve, reject) => {
      const method = options?.method || "GET"
      const body = options?.body

      const parsedUrl = new URL(url)
      const req = http.request(
        {
          hostname: parsedUrl.hostname,
          port: parsedUrl.port,
          path: parsedUrl.pathname,
          method,
          headers: body
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }
            : {},
          timeout: 5000
        },
        (res) => {
          let data = ""
          res.on("data", (chunk) => (data += chunk))
          res.on("end", () => {
            try {
              resolve(JSON.parse(data) as T)
            } catch {
              reject(new Error(`Invalid JSON from ${url}`))
            }
          })
        }
      )

      req.on("error", reject)
      req.on("timeout", () => {
        req.destroy()
        reject(new Error(`Timeout: ${url}`))
      })

      if (body) req.write(body)
      req.end()
    })
  }
}

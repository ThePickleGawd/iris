export type WidgetKind = "html" | "markdown" | "text" | "image" | "chart"

export interface WidgetSpec {
  id?: string
  title?: string
  kind: WidgetKind
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
}

export function normalizeWidgetSpec(raw: unknown): WidgetSpec | null {
  if (!raw || typeof raw !== "object") return null
  const obj = raw as Record<string, unknown>

  const payloadSource =
    obj.payload && typeof obj.payload === "object"
      ? (obj.payload as Record<string, unknown>)
      : obj
  const kind = inferKind(obj, payloadSource)
  if (!kind) return null

  const payload = buildPayload(kind, payloadSource)
  if (!payload) return null

  const spec: WidgetSpec = {
    id: coerceString(obj.id ?? obj.widget_id),
    title: coerceString(obj.title ?? obj.name ?? obj.widget_id),
    kind,
    width: coerceDimension(obj.width),
    height: coerceDimension(obj.height),
    css: obj.css ? String(obj.css) : undefined,
    payload
  }

  return spec
}

export function extractWidgetBlocks(text: string): { cleanText: string; widgets: WidgetSpec[] } {
  const widgets: WidgetSpec[] = []
  const regex = /```iris-widget\s*([\s\S]*?)```/g

  const cleanText = text.replace(regex, (_match, block) => {
    try {
      const parsed = JSON.parse(block)
      const normalized = normalizeWidgetSpec(parsed)
      if (normalized) widgets.push(normalized)
    } catch {
      // ignore invalid widget blocks
    }
    return ""
  }).trim()

  return { cleanText, widgets }
}

function inferKind(
  obj: Record<string, unknown>,
  payload: Record<string, unknown>
): WidgetKind | null {
  const rawKind = String(obj.kind || "").toLowerCase()
  if (rawKind === "html" || rawKind === "markdown" || rawKind === "text" || rawKind === "image" || rawKind === "chart") {
    return rawKind
  }
  if (typeof payload.html === "string") return "html"
  if (typeof payload.markdown === "string") return "markdown"
  if (typeof payload.text === "string") return "text"
  if (typeof payload.imageUrl === "string" || typeof payload.image_url === "string") return "image"
  if (payload.chartConfig !== undefined || payload.chart_config !== undefined) return "chart"
  return null
}

function buildPayload(
  kind: WidgetKind,
  payload: Record<string, unknown>
): WidgetSpec["payload"] | null {
  if (kind === "html") {
    const html = coerceString(payload.html)
    if (!html) return null
    return { html }
  }
  if (kind === "markdown") {
    const markdown = coerceString(payload.markdown)
    if (!markdown) return null
    return { markdown }
  }
  if (kind === "text") {
    const text = coerceString(payload.text)
    if (!text) return null
    return { text }
  }
  if (kind === "image") {
    const imageUrl = coerceString(payload.imageUrl ?? payload.image_url)
    if (!imageUrl) return null
    return { imageUrl }
  }

  const chartConfig = payload.chartConfig ?? payload.chart_config
  if (chartConfig === undefined) return null
  return { chartConfig }
}

function coerceString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : undefined
}

function coerceDimension(value: unknown): number | undefined {
  if (typeof value !== "number" && typeof value !== "string") return undefined
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return undefined
  const rounded = Math.round(parsed)
  if (rounded < 100) return 100
  if (rounded > 1600) return 1600
  return rounded
}

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
  const kind = String(obj.kind || "") as WidgetKind
  if (!kind || !["html", "markdown", "text", "image", "chart"].includes(kind)) return null

  const payload = (obj.payload || {}) as Record<string, unknown>

  const spec: WidgetSpec = {
    id: obj.id ? String(obj.id) : undefined,
    title: obj.title ? String(obj.title) : undefined,
    kind,
    width: typeof obj.width === "number" ? obj.width : undefined,
    height: typeof obj.height === "number" ? obj.height : undefined,
    css: obj.css ? String(obj.css) : undefined,
    payload: {
      html: payload.html ? String(payload.html) : undefined,
      markdown: payload.markdown ? String(payload.markdown) : undefined,
      text: payload.text ? String(payload.text) : undefined,
      imageUrl: payload.imageUrl ? String(payload.imageUrl) : undefined,
      chartConfig: payload.chartConfig
    }
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

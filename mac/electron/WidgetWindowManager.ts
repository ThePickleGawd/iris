import { BrowserWindow, screen } from "electron"

type WidgetKind = "html" | "markdown" | "text" | "image" | "chart"

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

export class WidgetWindowManager {
  private windows = new Map<string, BrowserWindow>()
  private nextOffset = 0
  private onClosedCallback: ((id: string) => void) | null = null

  public onWidgetClosed(callback: (id: string) => void): void {
    this.onClosedCallback = callback
  }

  public openWidget(spec: WidgetSpec): { success: boolean; id: string; error?: string } {
    try {
      const id = spec.id || `widget-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
      const existing = this.windows.get(id)
      const width = clampDimension(spec.width, 520, 280, 1600)
      const height = clampDimension(spec.height, 420, 200, 1200)
      const html = this.renderWidgetHtml(spec)
      const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`

      if (existing && !existing.isDestroyed()) {
        existing.setSize(width, height)
        void existing.loadURL(dataUrl)
        existing.show()
        existing.focus()
        return { success: true, id }
      }

      // Position to the right side of the screen, staggered
      const display = screen.getPrimaryDisplay()
      const { width: screenW, height: screenH } = display.workAreaSize
      const x = Math.max(0, screenW - width - 40)
      const y = Math.min(60 + this.nextOffset * 40, screenH - height - 40)
      this.nextOffset = (this.nextOffset + 1) % 8

      const win = new BrowserWindow({
        width,
        height,
        x,
        y,
        minWidth: 280,
        minHeight: 200,
        title: spec.title || "Iris Widget",
        titleBarStyle: "hiddenInset",
        vibrancy: "under-window",
        backgroundColor: "#0a0a0e",
        hasShadow: true,
        autoHideMenuBar: true,
        alwaysOnTop: true,
        webPreferences: {
          nodeIntegration: false,
          contextIsolation: true,
          sandbox: true
        }
      })

      void win.loadURL(dataUrl)

      win.on("closed", () => {
        this.windows.delete(id)
        this.onClosedCallback?.(id)
      })

      this.windows.set(id, win)
      return { success: true, id }
    } catch (error: any) {
      return { success: false, id: "", error: error?.message || String(error) }
    }
  }

  private renderWidgetHtml(spec: WidgetSpec): string {
    const encoded = Buffer.from(JSON.stringify(spec)).toString("base64")

    return `<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${escapeHtml(spec.title || "Iris Widget")}</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <style>
      :root {
        --text: rgba(255,255,255,0.88);
        --muted: rgba(255,255,255,0.48);
        --bg: #0a0a0e;
        --card: rgba(255,255,255,0.04);
        --border: rgba(255,255,255,0.08);
        --accent: #8b5cf6;
      }
      html, body {
        margin: 0; padding: 0;
        background: var(--bg);
        color: var(--text);
        font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        font-size: 13px;
        line-height: 1.55;
        -webkit-font-smoothing: antialiased;
        height: 100%;
      }
      body {
        display: flex;
        flex-direction: column;
      }
      /* Draggable title bar area */
      .titlebar {
        -webkit-app-region: drag;
        height: 38px;
        display: flex;
        align-items: center;
        padding: 0 76px 0 12px;
      }
      .titlebar-text {
        font-size: 11px;
        font-weight: 600;
        color: var(--muted);
        letter-spacing: 0.04em;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .wrap { padding: 0 14px 14px; flex: 1; display: flex; flex-direction: column; min-height: 0; }
      .content { -webkit-app-region: no-drag; flex: 1; display: flex; flex-direction: column; min-height: 0; }
      .widget-iframe {
        width: 100%;
        flex: 1;
        min-height: 0;
        border: 1px solid var(--border);
        border-radius: 10px;
        background: #0a0a0e;
      }
      .content img { max-width: 100%; height: auto; border-radius: 8px; }
      .content pre {
        background: rgba(0,0,0,0.4);
        color: #e2e8f0;
        border-radius: 8px;
        padding: 10px;
        overflow: auto;
        border: 1px solid var(--border);
        font-family: 'SF Mono', Menlo, ui-monospace, monospace;
        font-size: 12px;
      }
      .content code {
        background: rgba(255,255,255,0.06);
        padding: 1px 4px;
        border-radius: 4px;
        font-family: 'SF Mono', Menlo, ui-monospace, monospace;
        font-size: 0.9em;
      }
      .content pre code { background: transparent; padding: 0; }
      .content h1, .content h2, .content h3 { color: var(--text); margin: 0.6em 0 0.3em; }
      .content p { margin: 0 0 0.5em; }
      .content a { color: var(--accent); }
      .content table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
      .content th, .content td { padding: 6px 10px; border: 1px solid var(--border); text-align: left; }
      .content th { background: rgba(255,255,255,0.04); font-weight: 600; }
      ${spec.css || ""}
    </style>
  </head>
  <body>
    <div class="titlebar"></div>
    <div class="wrap">
      <div id="content" class="content"></div>
    </div>
    <script>
      const spec = JSON.parse(atob(${JSON.stringify(encoded)}));
      const content = document.getElementById('content');
      const looksLikeDocument = (value) => /<!doctype|<html[\\s>]|<head[\\s>]|<body[\\s>]/i.test(value || '');
      const runInlineScripts = (root) => {
        const scripts = root.querySelectorAll('script');
        scripts.forEach((node) => {
          const replacement = document.createElement('script');
          for (const attr of node.attributes) {
            replacement.setAttribute(attr.name, attr.value);
          }
          replacement.text = node.textContent || '';
          node.parentNode?.replaceChild(replacement, node);
        });
      };

      if (spec.kind === 'html') {
        const rawHtml = spec.payload?.html || '';
        if (looksLikeDocument(rawHtml)) {
          const iframe = document.createElement('iframe');
          iframe.className = 'widget-iframe';
          iframe.setAttribute('sandbox', 'allow-scripts allow-forms allow-popups');
          iframe.srcdoc = rawHtml;
          content.appendChild(iframe);
        } else {
          content.innerHTML = rawHtml;
          runInlineScripts(content);
        }
      } else if (spec.kind === 'markdown') {
        content.innerHTML = marked.parse(spec.payload?.markdown || '');
      } else if (spec.kind === 'text') {
        const pre = document.createElement('pre');
        pre.textContent = spec.payload?.text || '';
        pre.style.whiteSpace = 'pre-wrap';
        content.appendChild(pre);
      } else if (spec.kind === 'image') {
        const img = document.createElement('img');
        img.src = spec.payload?.imageUrl || '';
        img.alt = spec.title || 'widget-image';
        content.appendChild(img);
      } else if (spec.kind === 'chart') {
        const canvas = document.createElement('canvas');
        content.appendChild(canvas);
        try {
          new Chart(canvas.getContext('2d'), spec.payload?.chartConfig || { type: 'line', data: { labels: [], datasets: [] } });
        } catch (e) {
          const p = document.createElement('p');
          p.textContent = 'Invalid chart config';
          content.appendChild(p);
        }
      }
    </script>
  </body>
</html>`
  }
}

function escapeHtml(input: string): string {
  return input
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;")
}

function clampDimension(
  value: number | undefined,
  fallback: number,
  min: number,
  max: number
): number {
  const parsed = typeof value === "number" && Number.isFinite(value) ? Math.round(value) : fallback
  return Math.max(min, Math.min(max, parsed))
}

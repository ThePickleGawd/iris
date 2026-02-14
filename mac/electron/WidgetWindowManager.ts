import { BrowserWindow } from "electron"

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

  public openWidget(spec: WidgetSpec): { success: boolean; id: string; error?: string } {
    try {
      const id = spec.id || `widget-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
      const existing = this.windows.get(id)

      if (existing && !existing.isDestroyed()) {
        existing.focus()
        return { success: true, id }
      }

      const win = new BrowserWindow({
        width: spec.width ?? 520,
        height: spec.height ?? 420,
        minWidth: 280,
        minHeight: 200,
        title: spec.title || "Iris Widget",
        backgroundColor: "#ffffff",
        autoHideMenuBar: true,
        webPreferences: {
          nodeIntegration: false,
          contextIsolation: true,
          sandbox: true
        }
      })

      const html = this.renderWidgetHtml(spec)
      const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`
      win.loadURL(dataUrl)

      win.on("closed", () => {
        this.windows.delete(id)
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
      :root { --text:#0f172a; --muted:#64748b; --bg:#f8fafc; --card:#ffffff; --border:#dbe4ea; }
      html, body { margin:0; padding:0; background:var(--bg); color:var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
      .wrap { padding: 12px; }
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px; box-shadow: 0 4px 18px rgba(2,6,23,0.06); }
      .title { font-size: 12px; color: var(--muted); margin-bottom: 8px; }
      .content img { max-width: 100%; height: auto; border-radius: 8px; }
      .content pre { background:#0f172a; color:#f8fafc; border-radius:8px; padding:10px; overflow:auto; }
      .content code { background:#e2e8f0; padding:1px 4px; border-radius:4px; }
      .content pre code { background: transparent; padding: 0; }
      ${spec.css || ""}
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="title">${escapeHtml(spec.title || "Widget")}</div>
        <div id="content" class="content"></div>
      </div>
    </div>
    <script>
      const spec = JSON.parse(atob(${JSON.stringify(encoded)}));
      const content = document.getElementById('content');

      if (spec.kind === 'html') {
        content.innerHTML = spec.payload?.html || '';
      } else if (spec.kind === 'markdown') {
        content.innerHTML = marked.parse(spec.payload?.markdown || '');
      } else if (spec.kind === 'text') {
        const pre = document.createElement('pre');
        pre.textContent = spec.payload?.text || '';
        pre.style.whiteSpace = 'pre-wrap';
        pre.style.background = '#f8fafc';
        pre.style.color = '#0f172a';
        pre.style.border = '1px solid #dbe4ea';
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

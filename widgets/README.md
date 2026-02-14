# Iris Widget Library & Testbed

A curated library of polished, Apple-aesthetic HTML widgets and a testbed for iterative development.

## Quick Start

```bash
cd widgets
npm install
```

## Iteration Loop

1. Write/edit `widgets/lib/<name>/widget.html`
2. Capture screenshot:
   ```bash
   node capture.mjs lib/<name>/widget.html
   ```
3. Read the screenshot: `lib/<name>/screenshot.png`
4. Compare to reference: `lib/<name>/reference.png`
5. Iterate until screenshot matches reference quality
6. Update `meta.json` with final dimensions

## Capture Tool

```bash
# Basic — uses dimensions from meta.json
node capture.mjs lib/calculator/widget.html

# Custom dimensions
node capture.mjs lib/calculator/widget.html --width 360 --height 500

# Custom output path
node capture.mjs lib/calculator/widget.html --out /tmp/preview.png
```

## Testbed

Serve the widgets directory and open the testbed in a browser:

```bash
npx serve .
# Then open http://localhost:3000/testbed/
```

- **Gallery** (`testbed/index.html`): Browse all widgets with live iframes and screenshots
- **Viewer** (`testbed/viewer.html?widget=calculator`): Single widget at actual size

## Adding a Widget

1. Create `lib/<name>/` directory
2. Add `widget.html` — self-contained HTML (inline CSS/JS, no external deps)
3. Add `meta.json`:
   ```json
   {
     "name": "Widget Name",
     "description": "What it does",
     "defaultWidth": 320,
     "defaultHeight": 400,
     "accent": "#007aff",
     "tags": ["tool", "interactive"]
   }
   ```
4. Add `reference.png` — target visual to match
5. Run `node capture.mjs lib/<name>/widget.html` to generate `screenshot.png`
6. Add the widget slug to `lib/manifest.json`

## Available Widgets

| Widget | Size | Description |
|--------|------|-------------|
| `calculator` | 320×520 | Apple Calculator with +−×÷=C±% |
| `graph` | 420×380 | Function plotter with pan/zoom |
| `timer` | 320×340 | Stopwatch + countdown timer |

## Agent Usage

The Iris agent uses this library via **copy & adapt** — there is no runtime widget resolution. The agent reads a library widget's HTML and inlines it (modified as needed) into a `push_widget` call.

### When the user asks for an interactive widget

1. **Check the library first.** Read `widgets/lib/manifest.json` for available widgets.
2. **Read the matching `widget.html`** (e.g. `widgets/lib/calculator/widget.html`).
3. **Read `meta.json`** for the default `width`/`height` to pass to `push_widget`.
4. **Adapt the HTML** — change colors, labels, button text, add/remove features, resize — whatever the request needs. Keep it self-contained (inline CSS/JS only).
5. **Pass the adapted HTML** as the `html` field in `push_widget`.

### Example: user asks "give me a calculator"

```python
# 1. Read widgets/lib/calculator/widget.html → raw HTML string
# 2. Read widgets/lib/calculator/meta.json → {"defaultWidth": 320, "defaultHeight": 520}
# 3. Call push_widget with:
push_widget(
    html="<full adapted HTML>",
    type="html",
    width=320,
    height=520,
    ...
)
```

### When to write from scratch

If no library widget is close enough to adapt, write fresh HTML following the style guide in the system prompt. Consider adding polished results back to the library afterward.

### Developing new library widgets (for Claude Code)

Use the capture tool to iterate visually:

```
1. Write widgets/lib/<name>/widget.html
2. Run: node widgets/capture.mjs widgets/lib/<name>/widget.html --out /tmp/preview.png
3. Read /tmp/preview.png to see how it looks
4. Edit and re-capture until satisfied
5. Add meta.json and update lib/manifest.json
```

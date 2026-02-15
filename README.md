# Iris

An AI assistant that sees, hears, and draws across your Apple devices.

## The Problem

Siri can't look at your screen. It can't draw you a diagram. It can't watch what you're doing on your Mac and help you on your iPad at the same time. Current AI assistants are stuck in one device, one modality, one conversation.

## What Iris Does

Iris is an always-on AI that spans your Apple devices. It watches your screens, listens to your voice, and acts — drawing diagrams on your iPad, overlaying information on your Mac, and coordinating across both simultaneously.

- **Sees** — watches your Mac and iPad screens, understands what you're working on
- **Hears** — streams audio from any device for natural voice interaction
- **Draws** — renders diagrams, widgets, and visual plans directly onto your iPad canvas with Apple Pencil interaction
- **Thinks across devices** — your Mac and iPad are one unified workspace, not two isolated screens

## Use Cases

**Planning** — ask Iris to turn a plan into a diagram you can interact with on your iPad using Apple Pencil.

**Coding** — Iris watches your screen, understands your code, and can execute changes while you sketch architecture on the iPad.

**Math** — write a problem by hand, get hints and solutions overlaid right on your work.

**Visual** — sketch a rough diagram, get back a polished image or video.

Iris is **all-to-all** — every device in your Apple ecosystem can see, talk to, and control every other device. The AI doesn't live on one screen. It lives across all of them.

## Prerequisites

- **uv** (Python package/runtime manager)
- **Node.js + npm** (for the Mac Electron app)
- **Claude Code CLI** (`claude`) for live Claude integration
- **D2** — diagram renderer for flowcharts, architecture, and sequence diagrams:
  ```
  brew install d2
  ```

- **TinyTeX** — lightweight LaTeX distribution needed by Manim for math rendering:
  ```
  curl -sL "https://tinytex.yihui.org/install-bin-unix.sh" | sh
  tlmgr install standalone preview doublestroke relsize fundus-calligra wasysym physics dvisvgm rsfs wasy setspace babel-english
  ```

- **Backend Python dependencies** (Flask, Manim, etc.) — managed with [uv](https://docs.astral.sh/uv/):
  ```
  cd backend && uv sync
  ```

## Setup

1. Create your local env file:
   ```bash
   cp .env.example .env
   ```

2. Install backend dependencies:
   ```bash
   cd backend
   uv sync
   cd ..
   ```

3. Install Mac app dependencies:
   ```bash
   cd mac
   npm install
   cd ..
   ```

4. Install Iris helper CLIs globally:
   ```bash
   tools/claudei install
   ```
   This installs:
   - `claudei` → live Claude Code bridge
   - `iris` → iPad tools CLI (`draw`, `push-widget`, `read-screenshot`, `read-widget`)

## Run

- Start backend + Mac app together:
  ```bash
  ./run.sh
  ```

- Or run individually:
  - backend: `bash backend/run.sh`
  - mac app: `bash mac/run.sh`

## Claude Code + iPad Workflow

1. Link this Mac to the iPad:
   ```bash
   claudei link
   ```

2. Start a live Claude session from any project folder:
   ```bash
   claudei
   ```
   Optional:
   - `claudei --cwd /path/to/project`
   - `claudei --resume <session_id>`

3. Send prompts from Iris on iPad.
   On the first message of a linked Claude session, Iris now auto-injects a CLI bootstrap so Claude knows to use:
   - `iris tools list`
   - `iris tools describe <tool>`
   - `iris draw`
   - `iris push-widget`
   - `iris read-screenshot`
   - `iris read-widget`

## Iris CLI (Global)

After install, `iris` works from any directory:

```bash
iris tools list
iris tools describe draw
iris draw --svg-file /tmp/diagram.svg --scale 1.5
iris push-widget --html-file /tmp/widget.html --width 360 --height 260
iris read-screenshot --image-out /tmp/ipad.jpg
iris read-widget --name calculator
```

Default iPad base URL is `http://dylans-ipad.local:8935` and can be overridden with `IRIS_IPAD_URL`.

## Browser Automation Service

`browser/` contains a standalone browser-use integration that can execute browser actions from text + image context using Claude.

Quick start:

```
cd browser
./run.sh
```

See `browser/README.md` for API payload format and Playwright setup.

## More Docs

- `backend/README.md` — backend API details and endpoints
- `iPad/README.md` — iPad canvas API (`/api/v1/*`)
- `mac/README.md` — Electron app setup and packaging
- `CLAUDE.md` — Claude-focused workflow and tooling notes

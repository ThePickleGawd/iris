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

- **D2** — diagram renderer for flowcharts, architecture, and sequence diagrams:
  ```
  brew install d2
  ```

- **claude-commander** — PTY wrapper that lets Iris inject messages into a live Claude Code session via Unix socket:
  ```bash
  # macOS Apple Silicon (prebuilt)
  curl -L https://github.com/sstraus/claude-commander/releases/latest/download/claudec-macos-arm64 -o /usr/local/bin/claudec
  chmod +x /usr/local/bin/claudec

  # Or build from source (requires Rust)
  cargo install --git https://github.com/sstraus/claude-commander
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

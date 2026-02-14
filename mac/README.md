# Mac Interface

Local macOS desktop interface built with Electron + React, connected to an LM provider.

## Quick Start

1. Install dependencies:
```bash
npm install
```

2. Configure environment:
```bash
cp .env.example .env
```

3. Set one provider:
- Cloud LM (Claude): set `CLAUDE_API_KEY=...`
- Local LM (Ollama): set `USE_OLLAMA=true` (and optionally `OLLAMA_MODEL`, `OLLAMA_URL`)

4. Run in development:
```bash
npm start
```

5. Build app bundle:
```bash
npm run dist
```

## Environment Variables

```env
CLAUDE_API_KEY=your_api_key_here
CLAUDE_MODEL=claude-sonnet-4-5
# LM_API_KEY=your_api_key_here
# USE_OLLAMA=true
# OLLAMA_MODEL=llama3.2
# OLLAMA_URL=http://localhost:11434
```

## Notes

- `CLAUDE_API_KEY` is the primary cloud key.
- `CLAUDE_MODEL` defaults to `claude-sonnet-4-5` (set this if you want a pinned model version).
- `LM_API_KEY` is still accepted as a compatibility fallback.
- Screenshots and audio can be analyzed through the in-app flow.

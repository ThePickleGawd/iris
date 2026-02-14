# Mac Interface

Local macOS desktop interface built with Electron + React, connected to the Iris agent/backend.

## Quick Start

1. Install dependencies:
```bash
npm install
```

2. Configure environment:
```bash
cp .env.example .env
```

3. Configure backend endpoints in `.env` (or use defaults):
- `IRIS_AGENT_URL` for the agent server (default `http://localhost:8000`)
- `IRIS_BACKEND_URL` for backend storage APIs (default `http://localhost:8000`)

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
IRIS_AGENT_URL=http://localhost:8000
IRIS_BACKEND_URL=http://localhost:8000
IRIS_AGENT_NAME=iris
```

## Notes

- The Mac app is backend-only and does not call Anthropic/Ollama directly.
- Provider/model selection is handled by your backend agent service.
- Screenshots/audio are routed through the backend flow.

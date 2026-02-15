# Iris Browser Service (Stagehand + Browserbase)

`browser/` now runs a Node service powered by Stagehand.

It keeps the same Iris API contract:
- `GET /health`
- `POST /api/browser/run`

This means backend integration does not need changes.

The Stagehand agent system prompt is loaded from repo-root `skills.md` by default.
You can override this via `BROWSER_SYSTEM_PROMPT_PATH`.

## Modes

- `STAGEHAND_ENV=LOCAL`
  - Uses a local browser.
  - Set `BROWSER_STAGEHAND_HEADLESS=false` to see browser windows.
- `STAGEHAND_ENV=BROWSERBASE`
  - Uses Browserbase cloud browser sessions.
  - Requires `BROWSERBASE_API_KEY` and `BROWSERBASE_PROJECT_ID`.

## Required env

In repo root `.env` (or `browser/.env`):

- `ANTHROPIC_API_KEY`
- For Browserbase mode only:
  - `BROWSERBASE_API_KEY`
  - `BROWSERBASE_PROJECT_ID`

See `browser/.env.example` for full config.

## Run

```bash
cd browser
./run.sh
```

Service default: `http://localhost:8010`

## Request format

```json
{
  "instruction": "go to apple.com and click Learn more",
  "context_text": "",
  "start_url": "https://www.apple.com",
  "max_steps": 8
}
```

Response includes:
- `ok`
- `model`
- `task_prompt`
- `result.final_result`
- `result.confirmed_url`
- `result.page_title`

## Reliability Tuning

- `BROWSER_PRIMARY_ENGINE=browser_use` uses local browser-use CLI as the primary execution engine (recommended default)
- Set `BROWSER_PRIMARY_ENGINE=stagehand` to force Stagehand as primary path
- `BROWSER_STAGEHAND_ENABLE_AGENT=false` keeps Stagehand agent off by default (avoids long agent stalls)
- `BROWSER_STAGEHAND_AGENT_MODE=hybrid` for stronger autonomous navigation/click flows
- `BROWSER_STAGEHAND_EXECUTION_STRATEGY=deterministic_first` runs direct action plans before autonomous agenting
- `BROWSER_STAGEHAND_INIT_TIMEOUT_MS=20000` caps Stagehand/browser startup time
- `BROWSER_STAGEHAND_NAV_TIMEOUT_MS=30000` caps page navigation/open time
- `BROWSER_STAGEHAND_ACT_TIMEOUT_MS=25000` timeout budget for deterministic action steps
- `BROWSER_STAGEHAND_AGENT_TIMEOUT_MS=35000` timeout budget for Stagehand agent path
- `BROWSER_STAGEHAND_RETRIES=1` to auto-retry transient failures
- `BROWSER_STAGEHAND_RETRY_BACKOFF_MS=1200` retry delay
- `BROWSER_STAGEHAND_TIMEOUT_MS=60000` per-request timeout budget
- `BROWSER_STAGEHAND_DISABLE_API=true` to avoid Stagehand API dependency and run locally against your model key
- `BROWSER_STAGEHAND_SELF_HEAL=true` to improve resilience on dynamic UIs
- `BROWSER_STAGEHAND_DOM_SETTLE_TIMEOUT_MS=1800` to stabilize post-action DOM timing
- `BROWSER_ENABLE_BROWSER_USE_FALLBACK=true` final fallback path using local `browser-use` CLI in Chromium

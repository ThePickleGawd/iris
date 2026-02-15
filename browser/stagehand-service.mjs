import express from "express";
import dotenv from "dotenv";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { Stagehand } from "@browserbasehq/stagehand";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

dotenv.config({ path: path.join(repoRoot, ".env") });
dotenv.config({ path: path.join(__dirname, ".env"), override: true });

const app = express();
app.use(express.json({ limit: "2mb" }));

const HOST = process.env.BROWSER_SERVICE_HOST || "0.0.0.0";
const PORT = Number(process.env.BROWSER_SERVICE_PORT || 8010);
const TASK_TIMEOUT_MS = Math.max(
  15_000,
  Number(process.env.BROWSER_STAGEHAND_TIMEOUT_MS || 60_000),
);
const DEFAULT_STAGEHAND_ENV = (process.env.STAGEHAND_ENV || "LOCAL").trim().toUpperCase();
const STAGEHAND_RETRIES = Math.max(0, Number(process.env.BROWSER_STAGEHAND_RETRIES || 1));
const STAGEHAND_RETRY_BACKOFF_MS = Math.max(
  0,
  Number(process.env.BROWSER_STAGEHAND_RETRY_BACKOFF_MS || 1200),
);
const STAGEHAND_AGENT_MODE = (process.env.BROWSER_STAGEHAND_AGENT_MODE || "hybrid")
  .trim()
  .toLowerCase();
const STAGEHAND_ENABLE_AGENT = String(process.env.BROWSER_STAGEHAND_ENABLE_AGENT || "false")
  .trim()
  .toLowerCase() === "true";
const STAGEHAND_DISABLE_API = String(process.env.BROWSER_STAGEHAND_DISABLE_API || "true")
  .trim()
  .toLowerCase() === "true";
const STAGEHAND_SELF_HEAL = String(process.env.BROWSER_STAGEHAND_SELF_HEAL || "true")
  .trim()
  .toLowerCase() === "true";
const STAGEHAND_DOM_SETTLE_TIMEOUT_MS = Math.max(
  500,
  Number(process.env.BROWSER_STAGEHAND_DOM_SETTLE_TIMEOUT_MS || 1800),
);
const EXECUTION_STRATEGY = (process.env.BROWSER_STAGEHAND_EXECUTION_STRATEGY || "deterministic_first")
  .trim()
  .toLowerCase();
const ACT_TIMEOUT_MS = Math.max(
  8_000,
  Number(process.env.BROWSER_STAGEHAND_ACT_TIMEOUT_MS || Math.min(25_000, TASK_TIMEOUT_MS)),
);
const AGENT_TIMEOUT_MS = Math.max(
  8_000,
  Number(process.env.BROWSER_STAGEHAND_AGENT_TIMEOUT_MS || Math.min(35_000, TASK_TIMEOUT_MS)),
);
const STAGEHAND_INIT_TIMEOUT_MS = Math.max(
  5_000,
  Number(process.env.BROWSER_STAGEHAND_INIT_TIMEOUT_MS || 20_000),
);
const STAGEHAND_NAV_TIMEOUT_MS = Math.max(
  8_000,
  Number(process.env.BROWSER_STAGEHAND_NAV_TIMEOUT_MS || 30_000),
);
const ENABLE_BROWSER_USE_FALLBACK = String(process.env.BROWSER_ENABLE_BROWSER_USE_FALLBACK || "true")
  .trim()
  .toLowerCase() === "true";
const PRIMARY_ENGINE = (process.env.BROWSER_PRIMARY_ENGINE || "browser_use")
  .trim()
  .toLowerCase();
const BROWSER_USE_SESSION_PREFIX = (
  process.env.BROWSER_USE_SESSION_PREFIX || "iris-browser-fallback"
).trim();
const SKILLS_PROMPT_PATH = process.env.BROWSER_SYSTEM_PROMPT_PATH
  ? path.resolve(process.env.BROWSER_SYSTEM_PROMPT_PATH)
  : path.join(repoRoot, "skills.md");
const SKILLS_SYSTEM_PROMPT = (() => {
  try {
    return fs.readFileSync(SKILLS_PROMPT_PATH, "utf8").trim();
  } catch {
    return "";
  }
})();
const RAW_STAGEHAND_MODEL_NAME = (process.env.STAGEHAND_MODEL || "claude-3-7-sonnet-latest").trim();
const BASE_MODEL_NAME = RAW_STAGEHAND_MODEL_NAME.startsWith("anthropic/")
  ? RAW_STAGEHAND_MODEL_NAME
  : `anthropic/${RAW_STAGEHAND_MODEL_NAME}`;
const AGENT_MODEL_NAME = (
  process.env.STAGEHAND_AGENT_MODEL ||
  BASE_MODEL_NAME
).trim();

function requireEnv(name) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function firstUrl(text) {
  const raw = String(text || "");
  const match = raw.match(/https?:\/\/\S+/i);
  if (match && match[0]) return match[0].replace(/[.,)]$/, "");
  const bare = raw.match(/\b([a-zA-Z0-9-]+\.[a-zA-Z]{2,})(\/\S*)?\b/);
  if (!bare || !bare[0]) return "";
  return `https://${bare[0].replace(/[.,)]$/, "")}`;
}

function withTimeout(promise, timeoutMs, message) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(message || "Task timeout")), timeoutMs),
    ),
  ]);
}

function extractClickTarget(text) {
  const raw = String(text || "").trim();
  if (!raw) return "";
  const quoted = raw.match(/click(?:\s+on)?\s+(?:the\s+)?["']([^"']{1,120})["']/i);
  if (quoted && quoted[1]) return quoted[1].trim();
  const plain = raw.match(
    /click(?:\s+on)?\s+(?:the\s+)?([a-zA-Z0-9][a-zA-Z0-9\s_\-:/&]{0,120}?)(?:\s+(?:button|link|tab|menu|option))?(?:[.!?]|$)/i,
  );
  if (plain && plain[1]) return plain[1].trim();
  return "";
}

function composeTask({ instruction, contextText, startUrl }) {
  const pieces = [];
  pieces.push(`Primary instruction: ${instruction}`);
  if (contextText) pieces.push(`Context: ${contextText}`);
  if (startUrl) {
    pieces.push(`Required start URL: ${startUrl}`);
    pieces.push("First open the required URL in a new tab.");
  }
  pieces.push("Only perform the minimum actions needed and then stop.");
  return pieces.join("\n\n");
}

function composeAgentInstruction({ instruction, contextText, startUrl, clickTarget }) {
  const pieces = [];
  pieces.push(`User request: ${instruction}`);
  if (contextText) pieces.push(`Context: ${contextText}`);
  if (startUrl) pieces.push(`Open this URL first: ${startUrl}`);
  if (clickTarget) {
    pieces.push(`Then click the UI element labeled "${clickTarget}".`);
    pieces.push("If there are multiple matches, choose the most primary call-to-action.");
  }
  pieces.push("Autonomously navigate and finish the task.");
  pieces.push("Stop once the request is complete.");
  return pieces.join("\n\n");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isDeterministicInstruction(text) {
  const raw = String(text || "").toLowerCase();
  if (!raw) return false;
  return /(click|open|go to|navigate|compare|buy|select|choose|learn more)/i.test(raw);
}

function buildBrowserUseInstruction({ instruction, startUrl }) {
  const pieces = [];
  if (startUrl) pieces.push(`Open ${startUrl} first.`);
  pieces.push(instruction);
  pieces.push("Stop when complete.");
  return pieces.join(" ");
}

function runShellCommand(command, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn("zsh", ["-lc", command], {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) {
        reject(new Error(`Command timed out after ${timeoutMs}ms`));
        return;
      }
      if (code !== 0) {
        reject(new Error(stderr.trim() || stdout.trim() || `Command failed with exit code ${code}`));
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

async function runBrowserUseFallback({ instruction, startUrl, maxSteps }) {
  const fallbackInstruction = buildBrowserUseInstruction({ instruction, startUrl });
  const sessionName = `${BROWSER_USE_SESSION_PREFIX}-${Date.now()}`;
  const openCmd = startUrl
    ? `uvx "browser-use[cli]" --session "${sessionName}" --browser chromium --headed open "${startUrl}"`
    : "";
  const runCmd =
    `uvx "browser-use[cli]" --session "${sessionName}" --browser chromium --headed ` +
    `run "${fallbackInstruction.replace(/"/g, '\\"')}" --max-steps ${Math.max(4, Math.min(80, maxSteps))}`;
  const closeCmd = `uvx "browser-use[cli]" --session "${sessionName}" close || true`;
  const command = [openCmd, runCmd, closeCmd].filter(Boolean).join("; ");
  const output = await runShellCommand(command, TASK_TIMEOUT_MS + 15_000);
  const combined = `${output.stdout}\n${output.stderr}`.trim();
  const success = /success:\s*True/i.test(combined) || /done:\s*True/i.test(combined);
  if (!success) {
    throw new Error(`browser-use fallback did not report success. Output: ${combined.slice(0, 1200)}`);
  }
  return {
    success: true,
    output: combined.slice(0, 2000),
  };
}

async function withRetries(fn, attempts, backoffMs) {
  let lastError = null;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return await fn(i);
    } catch (error) {
      lastError = error;
      if (i >= attempts - 1) break;
      await sleep(backoffMs * (i + 1));
    }
  }
  throw lastError;
}

async function resolveActivePage(stagehand, startUrl) {
  if (stagehand && stagehand.page) {
    return stagehand.page;
  }

  const context = stagehand?.context;
  if (!context) {
    throw new Error("Stagehand context is unavailable");
  }

  if (typeof context.activePage === "function") {
    const active = context.activePage();
    if (active) return active;
  }

  if (typeof context.pages === "function") {
    const pages = context.pages();
    if (Array.isArray(pages) && pages.length > 0) {
      return pages[pages.length - 1];
    }
  }

  if (typeof context.newPage === "function") {
    return await context.newPage(startUrl || undefined);
  }

  throw new Error("Stagehand did not provide an active page");
}

async function runStagehandTask({ instruction, contextText, startUrl, maxSteps, keepAlive }) {
  if (PRIMARY_ENGINE === "browser_use") {
    const fallbackResult = await runBrowserUseFallback({
      instruction,
      startUrl,
      maxSteps,
    });
    return {
      ok: true,
      model: "browser-use-primary",
      task_prompt: composeTask({ instruction, contextText, startUrl }),
      image_summary: "",
      result: {
        final_result: fallbackResult.output || "Completed browser task via browser-use.",
        confirmed_url: startUrl || "",
        page_title: "",
        is_done: true,
        action_result: null,
        agent_result: null,
        agent_error: null,
        action_error: null,
        fallback_used: false,
        browser_use_fallback_used: true,
        browser_use_fallback_error: null,
        browser_use_fallback_result: fallbackResult,
      },
    };
  }

  const modelApiKey = (process.env.ANTHROPIC_API_KEY || "").trim();
  if (!modelApiKey) {
    throw new Error("ANTHROPIC_API_KEY is required");
  }
  const stagehandEnv = DEFAULT_STAGEHAND_ENV;

  const task = composeTask({ instruction, contextText, startUrl });
  const clickTarget = extractClickTarget(instruction);
  const agentInstruction = composeAgentInstruction({
    instruction,
    contextText,
    startUrl,
    clickTarget,
  });

  const stagehandOptions = {
    env: stagehandEnv,
    modelName: BASE_MODEL_NAME,
    model: BASE_MODEL_NAME,
    modelApiKey,
    headless:
      String(process.env.BROWSER_STAGEHAND_HEADLESS || "false").trim().toLowerCase() === "true",
    systemPrompt: SKILLS_SYSTEM_PROMPT || undefined,
    disableAPI: STAGEHAND_DISABLE_API,
    selfHeal: STAGEHAND_SELF_HEAL,
    domSettleTimeout: STAGEHAND_DOM_SETTLE_TIMEOUT_MS,
  };
  if (stagehandEnv === "BROWSERBASE") {
    stagehandOptions.apiKey = requireEnv("BROWSERBASE_API_KEY");
    stagehandOptions.projectId = requireEnv("BROWSERBASE_PROJECT_ID");
  }

  const executeStagehand = async () =>
    withRetries(
      async () => {
      const stagehand = new Stagehand(stagehandOptions);
      let page = null;
      try {
        if (typeof stagehand.init === "function") {
          await withTimeout(
            stagehand.init(),
            STAGEHAND_INIT_TIMEOUT_MS,
            `Stagehand init timed out after ${STAGEHAND_INIT_TIMEOUT_MS}ms`,
          );
        }

        page = await withTimeout(
          resolveActivePage(stagehand, startUrl),
          STAGEHAND_INIT_TIMEOUT_MS,
          `Resolving active page timed out after ${STAGEHAND_INIT_TIMEOUT_MS}ms`,
        );

        if (startUrl && typeof page.goto === "function") {
          await withTimeout(
            page.goto(startUrl, { waitUntil: "domcontentloaded", timeout: STAGEHAND_NAV_TIMEOUT_MS }),
            STAGEHAND_NAV_TIMEOUT_MS + 1000,
            `Navigation timed out after ${STAGEHAND_NAV_TIMEOUT_MS}ms`,
          );
        }

        const agentFactory =
          typeof stagehand.agent === "function" ? stagehand.agent.bind(stagehand) : null;
        const act =
          (typeof page.act === "function" && page.act.bind(page)) ||
          (typeof stagehand.act === "function" && stagehand.act.bind(stagehand));

        let actionResult = null;
        let agentResult = null;
        let agentError = null;
        let actionError = null;
        let browserUseFallbackResult = null;
        let browserUseFallbackError = null;
        let usedFallbackAct = false;
        const deterministicFirst =
          EXECUTION_STRATEGY === "deterministic_first" && isDeterministicInstruction(instruction);
        const runActFirst = Boolean(act) && (deterministicFirst || Boolean(clickTarget));
        const agentFirst = !runActFirst;

        if (runActFirst) {
          usedFallbackAct = true;
          const firstPrompt = clickTarget
            ? `Click "${clickTarget}" on the current page. If needed, scroll and then click exactly once.`
            : task;
          try {
            actionResult = await withTimeout(
              act(firstPrompt, { maxSteps: Math.min(maxSteps, 8) }),
              ACT_TIMEOUT_MS,
              `Stagehand act deterministic step timed out after ${ACT_TIMEOUT_MS}ms`,
            );
          } catch (error) {
            actionError = error instanceof Error ? error.message : String(error);
            try {
              actionResult = await withTimeout(
                act(task, { maxSteps: Math.min(maxSteps, 10) }),
                ACT_TIMEOUT_MS,
                `Stagehand act deterministic retry timed out after ${ACT_TIMEOUT_MS}ms`,
              );
              actionError = null;
            } catch (secondError) {
              actionError = secondError instanceof Error ? secondError.message : String(secondError);
            }
          }
        }

        if (STAGEHAND_ENABLE_AGENT && agentFactory && (agentFirst || !actionResult)) {
          const agent = agentFactory({
            mode: STAGEHAND_AGENT_MODE,
            systemPrompt: SKILLS_SYSTEM_PROMPT || undefined,
            model: AGENT_MODEL_NAME,
            executionModel: AGENT_MODEL_NAME,
          });
          try {
            agentResult = await withTimeout(
              agent.execute({
                instruction: agentInstruction,
                maxSteps,
                page,
              }),
              AGENT_TIMEOUT_MS,
              `Stagehand agent timed out after ${AGENT_TIMEOUT_MS}ms`,
            );
          } catch (error) {
            agentError = error instanceof Error ? error.message : String(error);
          }
        }

        const agentSucceeded = Boolean(agentResult?.success) || Boolean(agentResult?.completed);
        if (!actionResult && !agentSucceeded && clickTarget && act) {
          usedFallbackAct = true;
          try {
            actionResult = await withTimeout(
              act(`Click "${clickTarget}"`, { maxSteps: Math.min(maxSteps, 6) }),
              ACT_TIMEOUT_MS,
              `Stagehand act fallback timed out after ${ACT_TIMEOUT_MS}ms`,
            );
          } catch (error) {
            actionError = error instanceof Error ? error.message : String(error);
            try {
              actionResult = await withTimeout(
                act(
                  `Find and click the primary visible call-to-action matching "${clickTarget}". Scroll if needed, then click it once.`,
                  { maxSteps: Math.min(maxSteps, 8) },
                ),
                ACT_TIMEOUT_MS,
                `Stagehand act fallback retry timed out after ${ACT_TIMEOUT_MS}ms`,
              );
              actionError = null;
            } catch (secondError) {
              actionError = secondError instanceof Error ? secondError.message : String(secondError);
            }
          }
        } else if (!actionResult && !agentFactory && act) {
          usedFallbackAct = true;
          actionResult = await withTimeout(
            act(task, { maxSteps }),
            ACT_TIMEOUT_MS,
            `Stagehand act task timed out after ${ACT_TIMEOUT_MS}ms`,
          );
        }

        const fallbackSucceeded = Boolean(actionResult);
        if (!agentSucceeded && !fallbackSucceeded && ENABLE_BROWSER_USE_FALLBACK) {
          try {
            browserUseFallbackResult = await runBrowserUseFallback({
              instruction,
              startUrl,
              maxSteps,
            });
          } catch (error) {
            browserUseFallbackError = error instanceof Error ? error.message : String(error);
          }
        }

        const browserUseSucceeded = Boolean(browserUseFallbackResult?.success);
        if (!agentSucceeded && !fallbackSucceeded && !browserUseSucceeded) {
          throw new Error(
            agentError
              ? `Failed to execute task. Agent error: ${agentError}${
                  actionError ? `; act error: ${actionError}` : ""
                }${browserUseFallbackError ? `; browser-use error: ${browserUseFallbackError}` : ""}`
              : `Failed to execute task: no execution path succeeded.${
                  actionError ? ` Act error: ${actionError}.` : ""
                }${browserUseFallbackError ? ` browser-use error: ${browserUseFallbackError}.` : ""}`,
          );
        }

        let confirmedUrl = "";
        if (typeof page.url === "function") confirmedUrl = page.url();
        else if (typeof page.url === "string") confirmedUrl = page.url;

        let pageTitle = "";
        if (typeof page.title === "function") {
          pageTitle = await page.title();
        }

        return {
          ok: true,
          model: AGENT_MODEL_NAME,
          task_prompt: task,
          image_summary: "",
          result: {
            final_result:
              agentResult?.message ||
              browserUseFallbackResult?.output ||
              (usedFallbackAct
                ? "Completed browser task via Stagehand act fallback."
                : "Completed browser task with Stagehand agent."),
            confirmed_url: confirmedUrl,
            page_title: pageTitle,
            is_done: true,
            action_result: actionResult ?? null,
            agent_result: agentResult ?? null,
            agent_error: agentError,
            action_error: actionError,
            fallback_used: usedFallbackAct,
            browser_use_fallback_used: browserUseSucceeded,
            browser_use_fallback_error: browserUseFallbackError,
            browser_use_fallback_result: browserUseFallbackResult,
          },
        };
      } finally {
        if (!keepAlive && typeof stagehand.close === "function") {
          try {
            await withTimeout(
              stagehand.close(),
              5000,
              "Timed out while closing Stagehand browser session",
            );
          } catch {
            // no-op
          }
        }
      }
      },
      STAGEHAND_RETRIES + 1,
      STAGEHAND_RETRY_BACKOFF_MS,
    );

  try {
    return await executeStagehand();
  } catch (stagehandError) {
    if (!ENABLE_BROWSER_USE_FALLBACK) {
      throw stagehandError;
    }
    const fallbackResult = await runBrowserUseFallback({
      instruction,
      startUrl,
      maxSteps,
    });
    return {
      ok: true,
      model: "browser-use-fallback",
      task_prompt: task,
      image_summary: "",
      result: {
        final_result: fallbackResult.output || "Completed browser task via browser-use fallback.",
        confirmed_url: startUrl || "",
        page_title: "",
        is_done: true,
        action_result: null,
        agent_result: null,
        agent_error: stagehandError instanceof Error ? stagehandError.message : String(stagehandError),
        action_error: null,
        fallback_used: false,
        browser_use_fallback_used: true,
        browser_use_fallback_error: null,
        browser_use_fallback_result: fallbackResult,
      },
    };
  }
}

app.get("/health", (_req, res) => {
  const stagehandEnv = DEFAULT_STAGEHAND_ENV;
  res.json({
    ok: true,
    service: "iris-browser-stagehand",
    stagehand_env: stagehandEnv,
    browserbase_key_configured: Boolean((process.env.BROWSERBASE_API_KEY || "").trim()),
    browserbase_project_configured: Boolean((process.env.BROWSERBASE_PROJECT_ID || "").trim()),
    system_prompt_loaded: Boolean(SKILLS_SYSTEM_PROMPT),
    system_prompt_path: SKILLS_PROMPT_PATH,
    stagehand_model: BASE_MODEL_NAME,
    agent_model: AGENT_MODEL_NAME,
    agent_enabled: STAGEHAND_ENABLE_AGENT,
    agent_mode: STAGEHAND_AGENT_MODE,
    retries: STAGEHAND_RETRIES,
    timeout_ms: TASK_TIMEOUT_MS,
    primary_engine: PRIMARY_ENGINE,
    strategy: EXECUTION_STRATEGY,
    init_timeout_ms: STAGEHAND_INIT_TIMEOUT_MS,
    nav_timeout_ms: STAGEHAND_NAV_TIMEOUT_MS,
    act_timeout_ms: ACT_TIMEOUT_MS,
    agent_timeout_ms: AGENT_TIMEOUT_MS,
    disable_api: STAGEHAND_DISABLE_API,
    self_heal: STAGEHAND_SELF_HEAL,
    dom_settle_timeout_ms: STAGEHAND_DOM_SETTLE_TIMEOUT_MS,
    browser_use_fallback: ENABLE_BROWSER_USE_FALLBACK,
    anthropic_key_configured: Boolean((process.env.ANTHROPIC_API_KEY || "").trim()),
    model_key_configured: Boolean(
      (process.env.ANTHROPIC_API_KEY || "").trim(),
    ),
  });
});

app.post("/api/browser/run", async (req, res) => {
  const body = req.body;
  if (!body || typeof body !== "object") {
    res.status(400).json({ ok: false, error: "Expected JSON body" });
    return;
  }

  const instruction = String(body.instruction || "").trim();
  if (!instruction) {
    res.status(400).json({ ok: false, error: "Missing required field: instruction" });
    return;
  }

  const contextText = String(body.context_text || "");
  const startUrlRaw = String(body.start_url || "").trim();
  const startUrl = startUrlRaw || firstUrl(instruction) || firstUrl(contextText);
  const maxSteps = Math.max(1, Math.min(200, Number(body.max_steps || 8)));
  const keepAlive = Boolean(body.keep_alive);

  try {
    const result = await runStagehandTask({
      instruction,
      contextText,
      startUrl,
      maxSteps,
      keepAlive,
    });
    res.json(result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    res.status(500).json({ ok: false, error: message });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`[stagehand-service] listening on http://${HOST}:${PORT}`);
});

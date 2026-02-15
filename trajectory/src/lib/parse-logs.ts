import {
  ToolCall,
  TrajectoryMetadata,
  TrajectoryStep,
  TrajectoryFile,
  ComputedStats,
} from "./types";

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function asString(value: unknown, fallback = ""): string {
  if (typeof value === "string") return value;
  if (value == null) return fallback;
  return String(value);
}

function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function normalizeMetadata(value: unknown): TrajectoryMetadata | null {
  const row = asRecord(value);
  if (!row || row.type !== "metadata") return null;

  const startedAtRaw = asString(row.started_at).trim();
  const startedAt = startedAtRaw || new Date().toISOString();

  const metadata: TrajectoryMetadata = {
    type: "metadata",
    session_id: asString(row.session_id, "unknown"),
    agent: asString(row.agent, "iris"),
    model: asString(row.model, "unknown"),
    started_at: startedAt,
    task: asString(row.task, "Unknown task"),
  };

  const endedAt = asString(row.ended_at).trim();
  if (endedAt) metadata.ended_at = endedAt;
  if (Array.isArray(row.devices)) {
    metadata.devices = row.devices
      .map((d) => asString(d).trim())
      .filter(Boolean);
  }
  const systemPrompt = asString(row.system_prompt).trim();
  if (systemPrompt) metadata.system_prompt = systemPrompt;
  const sessionMetadata = asRecord(row.session_metadata);
  if (sessionMetadata) metadata.session_metadata = sessionMetadata;
  return metadata;
}

function normalizeToolCall(value: unknown, step: number, index: number): ToolCall | null {
  const row = asRecord(value);
  if (!row) return null;

  const name = asString(row.name).trim() || "unknown_tool";
  const input = asRecord(row.input) ?? {};

  const normalized: ToolCall = {
    id: asString(row.id).trim() || `tc_${step}_${index}`,
    name,
    input,
    result: Object.prototype.hasOwnProperty.call(row, "result") ? row.result : null,
  };

  const screenshotBase64 = asString(row.screenshot_base64).trim();
  if (screenshotBase64) normalized.screenshot_base64 = screenshotBase64;

  const widgetHtml = asString(row.widget_html);
  if (widgetHtml) normalized.widget_html = widgetHtml;

  const widgetSpec = asRecord(row.widget_spec);
  if (widgetSpec && typeof widgetSpec.html === "string") {
    normalized.widget_spec = {
      id: typeof widgetSpec.id === "string" ? widgetSpec.id : undefined,
      title: typeof widgetSpec.title === "string" ? widgetSpec.title : undefined,
      kind: typeof widgetSpec.kind === "string" ? widgetSpec.kind : undefined,
      width: typeof widgetSpec.width === "number" ? widgetSpec.width : undefined,
      height: typeof widgetSpec.height === "number" ? widgetSpec.height : undefined,
      html: widgetSpec.html,
      css: typeof widgetSpec.css === "string" ? widgetSpec.css : undefined,
      target_device:
        typeof widgetSpec.target_device === "string"
          ? widgetSpec.target_device
          : undefined,
    };
  }

  if (Object.prototype.hasOwnProperty.call(row, "duration_ms")) {
    normalized.duration_ms = Math.max(0, Math.trunc(asNumber(row.duration_ms, 0)));
  }
  const raw = asRecord(row.raw);
  if (raw) normalized.raw = raw;

  return normalized;
}

function normalizeMessageMeta(
  row: Record<string, unknown>
): {
  role?: string;
  message_id?: string;
  source?: string;
  device_id?: string;
  raw_message?: Record<string, unknown>;
} {
  const meta: {
    role?: string;
    message_id?: string;
    source?: string;
    device_id?: string;
    raw_message?: Record<string, unknown>;
  } = {};

  const role = asString(row.role).trim();
  if (role) meta.role = role;
  const messageId = asString(row.message_id).trim();
  if (messageId) meta.message_id = messageId;
  const source = asString(row.source).trim();
  if (source) meta.source = source;
  const deviceId = asString(row.device_id).trim();
  if (deviceId) meta.device_id = deviceId;
  const rawMessage = asRecord(row.raw_message);
  if (rawMessage) meta.raw_message = rawMessage;

  return meta;
}

function normalizeStep(value: unknown, index: number): TrajectoryStep | null {
  const row = asRecord(value);
  if (!row || typeof row.type !== "string") return null;

  const timestamp = asString(row.timestamp).trim() || new Date().toISOString();
  const step = Math.max(0, Math.trunc(asNumber(row.step, index)));
  const messageMeta = normalizeMessageMeta(row);

  if (row.type === "user_message") {
    const screenshots = Array.isArray(row.screenshots)
      ? row.screenshots
          .map((s) => {
            const parsed = asRecord(s);
            if (!parsed) return null;
            const device = asString(parsed.device).trim();
            const base64 = asString(parsed.base64).trim();
            if (!device || !base64) return null;
            return {
              device,
              base64,
              captured_at:
                typeof parsed.captured_at === "string" ? parsed.captured_at : undefined,
            };
          })
          .filter((s): s is NonNullable<typeof s> => s !== null)
      : undefined;

    const transcripts = Array.isArray(row.transcripts)
      ? row.transcripts.map((t) => asString(t)).filter((t) => t.length > 0)
      : undefined;

    return {
      type: "user_message",
      step,
      timestamp,
      content: asString(row.content),
      ...messageMeta,
      ...(screenshots && screenshots.length > 0 ? { screenshots } : {}),
      ...(transcripts && transcripts.length > 0 ? { transcripts } : {}),
    };
  }

  if (row.type === "agent_turn") {
    const toolCalls = Array.isArray(row.tool_calls)
      ? row.tool_calls
          .map((tc, tcIndex) => normalizeToolCall(tc, step, tcIndex))
          .filter((tc): tc is ToolCall => tc !== null)
      : [];

    return {
      type: "agent_turn",
      step,
      timestamp,
      thought: asString(row.thought),
      ...messageMeta,
      tool_calls: toolCalls,
      duration_ms: Math.max(0, Math.trunc(asNumber(row.duration_ms, 0))),
    };
  }

  if (row.type === "session_message") {
    const role = asString(row.role).trim() || "unknown";
    return {
      type: "session_message",
      step,
      timestamp,
      role,
      content: asString(row.content),
      ...messageMeta,
    };
  }

  if (row.type === "final_response") {
    return {
      type: "final_response",
      step,
      timestamp,
      content: asString(row.content),
      total_duration_ms: Math.max(0, Math.trunc(asNumber(row.total_duration_ms, 0))),
      ...messageMeta,
    };
  }

  return null;
}

export function parseJSONL(content: string): {
  metadata: TrajectoryMetadata | null;
  steps: TrajectoryStep[];
} {
  const lines = content.split("\n").filter((line) => line.trim().length > 0);
  let metadata: TrajectoryMetadata | null = null;
  const steps: TrajectoryStep[] = [];

  for (const [lineIndex, line] of lines.entries()) {
    try {
      const parsed: unknown = JSON.parse(line);
      const parsedMetadata = normalizeMetadata(parsed);
      if (parsedMetadata) {
        metadata = parsedMetadata;
        continue;
      }

      const step = normalizeStep(parsed, lineIndex);
      if (step) steps.push(step);
    } catch {
      console.warn("Failed to parse line:", line.substring(0, 80));
    }
  }

  steps.sort((a, b) => a.step - b.step);
  return { metadata, steps };
}

export function computeStats(steps: TrajectoryStep[]): ComputedStats {
  let totalToolCalls = 0;
  let screenshotCount = 0;
  let widgetCount = 0;
  let bashCount = 0;
  let searchCount = 0;
  let totalDurationMs = 0;
  const toolBreakdown: Record<string, number> = {};

  for (const step of steps) {
    if (step.type === "agent_turn") {
      totalDurationMs += step.duration_ms || 0;
      for (const tc of step.tool_calls) {
        totalToolCalls++;
        toolBreakdown[tc.name] = (toolBreakdown[tc.name] || 0) + 1;
        if (tc.name === "read_screenshot") screenshotCount++;
        if (tc.name === "push_widget") widgetCount++;
        if (tc.name === "run_bash") bashCount++;
        if (tc.name === "web_search") searchCount++;
      }
    } else if (step.type === "final_response") {
      totalDurationMs = step.total_duration_ms || totalDurationMs;
    }
  }

  return {
    totalSteps: steps.length,
    totalToolCalls,
    screenshotCount,
    widgetCount,
    bashCount,
    searchCount,
    totalDurationMs,
    toolBreakdown,
  };
}

export function parseTrajectoryFile(
  fileName: string,
  content: string
): TrajectoryFile {
  const { metadata, steps } = parseJSONL(content);
  const computed = computeStats(steps);

  return {
    fileName,
    metadata: metadata || {
      type: "metadata",
      session_id: "unknown",
      agent: "iris",
      model: "unknown",
      started_at: new Date().toISOString(),
      task: "Unknown task",
    },
    steps,
    computed,
  };
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const min = Math.floor(ms / 60_000);
  const sec = ((ms % 60_000) / 1000).toFixed(0);
  return `${min}m ${sec}s`;
}

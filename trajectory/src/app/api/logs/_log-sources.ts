import { readdir, readFile, stat } from "fs/promises";
import { basename, delimiter, isAbsolute, join, relative, resolve } from "path";

const TRAJECTORY_FILE_EXT = ".jsonl";
const SESSION_FILE_EXT = ".json";
const SCREENSHOT_META_FILE_EXT = ".json";
const SCREENSHOT_ID_REGEX = /screenshot id\s*["']?([0-9a-f-]{36})["']?/gi;

type LogSourceKind = "trajectory" | "session";

interface LogDirSource {
  dir: string;
  kind: LogSourceKind;
  ext: string;
}

interface SessionScreenshot {
  id: string;
  sessionId: string;
  deviceId: string;
  createdAtMs: number;
  filePath: string;
}

export interface TrajectoryLogEntry {
  id: string;
  fileName: string;
  source: string;
  modifiedAt: number;
}

function encodePath(path: string): string {
  return Buffer.from(path, "utf-8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodePath(encoded: string): string | null {
  try {
    const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    return Buffer.from(padded, "base64").toString("utf-8");
  } catch {
    return null;
  }
}

function parseConfiguredDirs(raw: string): string[] {
  if (!raw.trim()) return [];

  return raw
    .split(/[\n,]/)
    .flatMap((chunk) => chunk.split(delimiter))
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => resolve(process.cwd(), value));
}

function configuredTrajectoryDirs(): string[] {
  const raw = process.env.TRAJECTORY_LOG_DIRS || process.env.AGENT_LOG_DIR || "";
  return parseConfiguredDirs(raw);
}

function configuredSessionDirs(): string[] {
  const raw = process.env.TRAJECTORY_SESSION_DIRS || process.env.AGENT_SESSION_DIR || "";
  return parseConfiguredDirs(raw);
}

function configuredScreenshotMetaDirs(): string[] {
  const raw =
    process.env.TRAJECTORY_SCREENSHOT_META_DIRS || process.env.AGENT_SCREENSHOT_META_DIR || "";
  return parseConfiguredDirs(raw);
}

function defaultTrajectoryDirs(): string[] {
  const cwd = process.cwd();
  return [
    // Legacy location.
    join(cwd, "..", "agents", "log"),
    // Common backend locations.
    join(cwd, "..", "backend", "data", "trajectories"),
    join(cwd, "..", "backend", "data", "logs"),
    join(cwd, "..", "backend", "logs"),
    // Local demo/sample logs.
    join(cwd, "public", "demo"),
  ].map((dir) => resolve(dir));
}

function defaultSessionDirs(): string[] {
  const cwd = process.cwd();
  return [
    // Iris backend session store; convert to trajectory schema on read.
    join(cwd, "..", "backend", "data", "sessions"),
  ].map((dir) => resolve(dir));
}

function defaultScreenshotMetaDirs(): string[] {
  const cwd = process.cwd();
  return [join(cwd, "..", "backend", "data", "screenshot_meta")].map((dir) => resolve(dir));
}

function allScreenshotMetaDirs(): string[] {
  return [...new Set([...configuredScreenshotMetaDirs(), ...defaultScreenshotMetaDirs()])];
}

function toSources(dirs: string[], kind: LogSourceKind): LogDirSource[] {
  const ext = kind === "trajectory" ? TRAJECTORY_FILE_EXT : SESSION_FILE_EXT;
  return dirs.map((dir) => ({ dir, kind, ext }));
}

function allLogSources(): LogDirSource[] {
  const merged = [
    ...toSources(configuredTrajectoryDirs(), "trajectory"),
    ...toSources(defaultTrajectoryDirs(), "trajectory"),
    ...toSources(configuredSessionDirs(), "session"),
    ...toSources(defaultSessionDirs(), "session"),
  ];

  const seen = new Set<string>();
  const deduped: LogDirSource[] = [];
  for (const source of merged) {
    const key = `${source.kind}:${source.dir}`;
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(source);
  }
  return deduped;
}

function isInsideDir(path: string, dir: string): boolean {
  const rel = relative(dir, path);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

function isAllowedLogPath(path: string): boolean {
  return allLogSources().some(
    (source) => path.endsWith(source.ext) && isInsideDir(path, source.dir)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function stringifyUnknown(value: unknown): string {
  if (typeof value === "string") return value;
  if (value == null) return "";
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function normalizeSessionMessageContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return stringifyUnknown(content);

  const chunks: string[] = [];
  for (const item of content) {
    if (!isRecord(item)) {
      chunks.push(stringifyUnknown(item));
      continue;
    }

    const kind = typeof item.type === "string" ? item.type.trim() : "";
    if (
      kind === "input_text" ||
      kind === "output_text" ||
      kind === "text" ||
      kind === "summary_text"
    ) {
      const text = asNonEmptyString(item.text);
      if (text) chunks.push(text);
      continue;
    }

    if (kind.includes("image")) {
      const source = isRecord(item.source) ? item.source : null;
      const mediaType = asNonEmptyString(source?.media_type);
      const imageUrl = asNonEmptyString(item.image_url);
      const label = mediaType || imageUrl || "embedded";
      chunks.push(`[image: ${label}]`);
      continue;
    }

    chunks.push(stringifyUnknown(item));
  }

  return chunks.join("\n\n").trim();
}

function extractSystemPrompt(parsed: Record<string, unknown>): string | null {
  const directCandidates = [
    parsed.system_prompt,
    parsed.system,
    parsed.prompt,
  ];
  for (const candidate of directCandidates) {
    const value = asNonEmptyString(candidate);
    if (value) return value;
  }

  const metadata = isRecord(parsed.metadata) ? parsed.metadata : null;
  if (metadata) {
    const metadataCandidates = [
      metadata.system_prompt,
      metadata.system,
      metadata.base_instructions,
      metadata.instructions,
      metadata.prompt,
    ];
    for (const candidate of metadataCandidates) {
      const value = asNonEmptyString(candidate);
      if (value) return value;
    }
  }

  const rawMessages = Array.isArray(parsed.messages) ? parsed.messages : [];
  for (const item of rawMessages) {
    if (!isRecord(item)) continue;
    const role = asNonEmptyString(item.role)?.toLowerCase();
    if (role !== "system" && role !== "developer") continue;
    const content = normalizeSessionMessageContent(item.content);
    if (content.trim()) return content;
  }

  return null;
}

function parseTimestampMs(value: unknown): number {
  if (typeof value !== "string" || !value.trim()) return 0;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : 0;
}

function extractScreenshotIdsFromText(text: string): string[] {
  const ids: string[] = [];
  SCREENSHOT_ID_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null = null;
  while ((match = SCREENSHOT_ID_REGEX.exec(text)) !== null) {
    const id = match[1]?.trim();
    if (id) ids.push(id);
  }
  return ids;
}

async function loadSessionScreenshots(sessionId: string): Promise<SessionScreenshot[]> {
  const entries: SessionScreenshot[] = [];

  for (const dir of allScreenshotMetaDirs()) {
    let files: string[] = [];
    try {
      const dirEntries = await readdir(dir, { withFileTypes: true });
      files = dirEntries
        .filter((entry) => entry.isFile() && entry.name.endsWith(SCREENSHOT_META_FILE_EXT))
        .map((entry) => join(dir, entry.name));
    } catch {
      continue;
    }

    for (const path of files) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(await readFile(path, "utf-8"));
      } catch {
        continue;
      }
      if (!isRecord(parsed)) continue;

      const rowSessionId = typeof parsed.session_id === "string" ? parsed.session_id.trim() : "";
      if (!rowSessionId || rowSessionId !== sessionId) continue;

      const id = typeof parsed.id === "string" ? parsed.id.trim() : "";
      const filePath = typeof parsed.file_path === "string" ? parsed.file_path.trim() : "";
      if (!id || !filePath) continue;

      entries.push({
        id,
        sessionId: rowSessionId,
        deviceId: typeof parsed.device_id === "string" ? parsed.device_id.trim() : "",
        createdAtMs: parseTimestampMs(parsed.created_at),
        filePath,
      });
    }
  }

  entries.sort((a, b) => a.createdAtMs - b.createdAtMs || a.id.localeCompare(b.id));
  return entries;
}

function chooseScreenshotForToolCall(
  screenshots: SessionScreenshot[],
  screenshotById: Map<string, SessionScreenshot>,
  consumedScreenshotIds: Set<string>,
  pendingScreenshotIds: string[],
  messageTsMs: number,
  toolCallInput: Record<string, unknown>
): SessionScreenshot | null {
  while (pendingScreenshotIds.length > 0) {
    const id = pendingScreenshotIds.shift();
    if (!id) break;
    const row = screenshotById.get(id);
    if (!row) continue;
    if (consumedScreenshotIds.has(row.id)) continue;
    return row;
  }

  const preferredDevice =
    typeof toolCallInput.device === "string" ? toolCallInput.device.trim() : "";

  const byTime = screenshots.filter(
    (ss) =>
      !consumedScreenshotIds.has(ss.id) &&
      (messageTsMs <= 0 || ss.createdAtMs <= messageTsMs + 10_000)
  );
  if (byTime.length === 0) return null;

  if (preferredDevice) {
    const sameDevice = byTime.filter((ss) => ss.deviceId === preferredDevice);
    if (sameDevice.length > 0) {
      return sameDevice[sameDevice.length - 1];
    }
  }

  return byTime[byTime.length - 1];
}

async function loadScreenshotBase64(
  row: SessionScreenshot,
  cache: Map<string, string | null>
): Promise<string | null> {
  if (cache.has(row.id)) return cache.get(row.id) ?? null;
  try {
    const buf = await readFile(row.filePath);
    const base64 = Buffer.from(buf).toString("base64");
    cache.set(row.id, base64);
    return base64;
  } catch {
    cache.set(row.id, null);
    return null;
  }
}

function normalizeSessionToolCalls(
  value: unknown,
  step: number
): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) return [];

  const toolCalls: Array<Record<string, unknown>> = [];
  for (const [index, item] of value.entries()) {
    if (!isRecord(item)) continue;

    const name =
      typeof item.name === "string" && item.name.trim()
        ? item.name.trim()
        : "unknown_tool";

    const explicitInput = isRecord(item.input) ? { ...item.input } : {};
    const input: Record<string, unknown> = { ...explicitInput };
    if (typeof item.arguments === "string" && item.arguments.trim()) {
      try {
        const parsedArgs = JSON.parse(item.arguments);
        if (isRecord(parsedArgs)) {
          Object.assign(input, parsedArgs);
        }
      } catch {
        // Keep raw arguments as-is when parsing fails.
        input.arguments = item.arguments;
      }
    }
    for (const [key, itemValue] of Object.entries(item)) {
      if (
        key === "id" ||
        key === "name" ||
        key === "input" ||
        key === "arguments" ||
        key === "result" ||
        key === "duration_ms" ||
        key === "screenshot_base64" ||
        key === "widget_html" ||
        key === "widget_spec" ||
        key === "raw"
      ) {
        continue;
      }
      input[key] = itemValue;
    }

    const toolCall: Record<string, unknown> = {
      id:
        typeof item.id === "string" && item.id.trim()
          ? item.id.trim()
          : `tc_${step}_${index}`,
      name,
      input,
      result: Object.prototype.hasOwnProperty.call(item, "result")
        ? item.result
        : null,
    };

    if (typeof item.duration_ms === "number" && Number.isFinite(item.duration_ms)) {
      toolCall.duration_ms = Math.max(0, Math.trunc(item.duration_ms));
    }
    if (typeof item.screenshot_base64 === "string") {
      toolCall.screenshot_base64 = item.screenshot_base64;
    }
    if (typeof item.widget_html === "string") {
      toolCall.widget_html = item.widget_html;
    }
    if (isRecord(item.widget_spec)) {
      toolCall.widget_spec = item.widget_spec;
    }
    toolCall.raw = item;

    toolCalls.push(toolCall);
  }

  return toolCalls;
}

async function toSessionTrajectoryJSONL(rawSession: string): Promise<string | null> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawSession);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;

  const sessionId =
    typeof parsed.id === "string" && parsed.id.trim() ? parsed.id.trim() : "unknown-session";
  const model =
    typeof parsed.model === "string" && parsed.model.trim() ? parsed.model.trim() : "unknown";
  const startedAt =
    typeof parsed.created_at === "string" && parsed.created_at.trim()
      ? parsed.created_at.trim()
      : new Date().toISOString();
  const endedAt =
    typeof parsed.updated_at === "string" && parsed.updated_at.trim()
      ? parsed.updated_at.trim()
      : undefined;

  const rawMessages = Array.isArray(parsed.messages) ? parsed.messages : [];
  const messages = rawMessages.filter(isRecord);
  const firstUser = messages.find((msg) => {
    const role = typeof msg.role === "string" ? msg.role.trim().toLowerCase() : "";
    if (role !== "user") return false;
    return normalizeSessionMessageContent(msg.content).trim().length > 0;
  });
  const firstUserContent = firstUser ? normalizeSessionMessageContent(firstUser.content) : "";
  const task = firstUserContent.trim() ? firstUserContent.trim().slice(0, 200) : "Session replay";
  const systemPrompt = extractSystemPrompt(parsed);
  const sessionMetadata = isRecord(parsed.metadata) ? parsed.metadata : null;

  const screenshots = await loadSessionScreenshots(sessionId);
  const screenshotById = new Map(screenshots.map((row) => [row.id, row]));
  const consumedScreenshotIds = new Set<string>();
  const pendingScreenshotIds: string[] = [];
  const screenshotBase64ById = new Map<string, string | null>();

  const lines: Array<Record<string, unknown>> = [];
  const metadata: Record<string, unknown> = {
    type: "metadata",
    session_id: sessionId,
    agent: "iris",
    model,
    started_at: startedAt,
    task,
  };
  if (endedAt) metadata.ended_at = endedAt;
  if (systemPrompt) metadata.system_prompt = systemPrompt;
  if (sessionMetadata) metadata.session_metadata = sessionMetadata;
  lines.push(metadata);

  let step = 0;
  const hasExplicitSystemMessage = messages.some((message) => {
    const role = typeof message.role === "string" ? message.role.trim().toLowerCase() : "";
    return role === "system" || role === "developer";
  });
  if (systemPrompt && !hasExplicitSystemMessage) {
    lines.push({
      type: "session_message",
      step,
      timestamp: startedAt,
      role: "system",
      content: systemPrompt,
      source: "session.metadata",
    });
    step += 1;
  }

  let lastAssistant: { content: string; timestamp: string; meta: Record<string, unknown> } | null =
    null;
  let lastRole = "";
  for (const message of messages) {
    const role = typeof message.role === "string" ? message.role.trim().toLowerCase() : "unknown";
    const content = normalizeSessionMessageContent(message.content);
    const timestamp =
      typeof message.created_at === "string" && message.created_at.trim()
        ? message.created_at.trim()
        : new Date().toISOString();
    const messageMeta: Record<string, unknown> = {
      role,
      message_id: typeof message.id === "string" ? message.id : undefined,
      source: typeof message.source === "string" ? message.source : undefined,
      device_id: typeof message.device_id === "string" ? message.device_id : undefined,
      raw_message: message,
    };
    lastRole = role;

    if (role === "user") {
      const screenshotIds = extractScreenshotIdsFromText(content);
      for (const screenshotId of screenshotIds) {
        pendingScreenshotIds.push(screenshotId);
      }

      const userScreenshots: Array<Record<string, unknown>> = [];
      for (const screenshotId of [...new Set(screenshotIds)]) {
        const screenshot = screenshotById.get(screenshotId);
        if (!screenshot) continue;
        const base64 = await loadScreenshotBase64(screenshot, screenshotBase64ById);
        if (!base64) continue;
        const screenshotRow: Record<string, unknown> = {
          device: screenshot.deviceId || "unknown",
          base64,
        };
        if (screenshot.createdAtMs > 0) {
          screenshotRow.captured_at = new Date(screenshot.createdAtMs).toISOString();
        }
        userScreenshots.push(screenshotRow);
      }

      const userLine: Record<string, unknown> = {
        type: "user_message",
        step,
        timestamp,
        content,
        ...messageMeta,
      };
      if (userScreenshots.length > 0) userLine.screenshots = userScreenshots;

      lines.push(userLine);
      step += 1;
      continue;
    }

    if (role !== "assistant") {
      lines.push({
        type: "session_message",
        step,
        timestamp,
        role,
        content,
        ...messageMeta,
      });
      step += 1;
      continue;
    }

    const toolCalls = normalizeSessionToolCalls(message.tool_calls, step);
    const messageTsMs = parseTimestampMs(timestamp);

    for (const toolCall of toolCalls) {
      if (toolCall.name !== "read_screenshot") continue;
      const toolInput = isRecord(toolCall.input) ? toolCall.input : {};
      let screenshot = chooseScreenshotForToolCall(
        screenshots,
        screenshotById,
        consumedScreenshotIds,
        pendingScreenshotIds,
        messageTsMs,
        toolInput
      );
      if (!screenshot) continue;

      let base64 = await loadScreenshotBase64(screenshot, screenshotBase64ById);
      if (!base64) {
        const primaryScreenshotId = screenshot.id;
        const fallback = [...screenshots]
          .reverse()
          .find(
            (row) =>
              row.id !== primaryScreenshotId &&
              !consumedScreenshotIds.has(row.id) &&
              (messageTsMs <= 0 || row.createdAtMs <= messageTsMs + 10_000)
          );
        if (fallback) {
          const fallbackBase64 = await loadScreenshotBase64(fallback, screenshotBase64ById);
          if (fallbackBase64) {
            screenshot = fallback;
            base64 = fallbackBase64;
          }
        }
      }

      consumedScreenshotIds.add(screenshot.id);

      if (!toolInput.device && screenshot.deviceId) {
        toolInput.device = screenshot.deviceId;
      }
      toolCall.input = toolInput;

      if (base64) {
        toolCall.screenshot_base64 = base64;
      }

      if (toolCall.result == null) {
        const device = screenshot.deviceId || "unknown";
        toolCall.result = `Screenshot captured from ${device}`;
      }
    }

    lines.push({
      type: "agent_turn",
      step,
      timestamp,
      thought: content,
      ...messageMeta,
      tool_calls: toolCalls,
      duration_ms: 0,
    });
    lastAssistant = { content, timestamp, meta: messageMeta };
    step += 1;
  }

  if (lastAssistant && lastRole === "assistant") {
    lines.push({
      type: "final_response",
      step,
      timestamp: lastAssistant.timestamp,
      content: lastAssistant.content,
      total_duration_ms: 0,
      ...lastAssistant.meta,
    });
  }

  return `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`;
}

async function readLogContent(path: string): Promise<string | null> {
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch {
    return null;
  }

  if (path.endsWith(SESSION_FILE_EXT)) {
    return await toSessionTrajectoryJSONL(raw);
  }
  return raw;
}

export async function listTrajectoryLogs(): Promise<TrajectoryLogEntry[]> {
  const cwd = process.cwd();
  const entries: TrajectoryLogEntry[] = [];

  for (const source of allLogSources()) {
    let files: string[] = [];
    try {
      const dirEntries = await readdir(source.dir, { withFileTypes: true });
      files = dirEntries
        .filter((entry) => entry.isFile() && entry.name.endsWith(source.ext))
        .map((entry) => entry.name);
    } catch {
      continue;
    }

    const rows = await Promise.all(
      files.map(async (fileName): Promise<TrajectoryLogEntry> => {
        const path = resolve(source.dir, fileName);
        let modifiedAt = 0;
        try {
          modifiedAt = (await stat(path)).mtimeMs;
        } catch {
          // Keep 0 for unknown mtimes.
        }

        const sourceLabel = relative(cwd, source.dir) || ".";
        return {
          id: encodePath(path),
          fileName,
          source: sourceLabel,
          modifiedAt,
        };
      })
    );

    entries.push(...rows);
  }

  entries.sort((a, b) => b.modifiedAt - a.modifiedAt || a.fileName.localeCompare(b.fileName));
  return entries;
}

async function readByLegacyFileName(fileName: string): Promise<string | null> {
  const isSupportedExt =
    fileName.endsWith(TRAJECTORY_FILE_EXT) || fileName.endsWith(SESSION_FILE_EXT);
  if (!isSupportedExt || basename(fileName) !== fileName) {
    return null;
  }

  for (const source of allLogSources()) {
    if (!fileName.endsWith(source.ext)) continue;
    const content = await readLogContent(join(source.dir, fileName));
    if (content !== null) return content;
  }
  return null;
}

async function readByEncodedPath(encodedPath: string): Promise<string | null> {
  const decoded = decodePath(encodedPath);
  if (!decoded) return null;

  const path = resolve(decoded);
  if (!isAllowedLogPath(path)) return null;

  return readLogContent(path);
}

export async function readTrajectoryLog(idOrFileName: string): Promise<string | null> {
  const byId = await readByEncodedPath(idOrFileName);
  if (byId !== null) return byId;
  return readByLegacyFileName(idOrFileName);
}

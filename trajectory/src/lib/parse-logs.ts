import {
  TrajectoryMetadata,
  TrajectoryStep,
  TrajectoryFile,
  ComputedStats,
} from "./types";

export function parseJSONL(content: string): {
  metadata: TrajectoryMetadata | null;
  steps: TrajectoryStep[];
} {
  const lines = content.trim().split("\n").filter(Boolean);
  let metadata: TrajectoryMetadata | null = null;
  const steps: TrajectoryStep[] = [];

  for (const line of lines) {
    try {
      const parsed = JSON.parse(line);
      if (parsed.type === "metadata") {
        metadata = parsed;
      } else {
        steps.push(parsed);
      }
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

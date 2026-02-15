"use client";

import { useState } from "react";
import { TrajectoryFile, TrajectoryStep, ToolCall, AgentTurn } from "@/lib/types";
import { WidgetPreview } from "./WidgetPreview";
import { cn } from "@/lib/utils";
import { formatDuration } from "@/lib/parse-logs";
import {
  Camera,
  Layout,
  Terminal,
  Search,
  Mic,
  ChevronDown,
  ChevronRight,
  Clock,
  Image,
  Globe,
} from "lucide-react";

interface Props {
  trajectory: TrajectoryFile;
  selectedStep: number;
}

const toolMeta: Record<
  string,
  { icon: typeof Camera; label: string; color: string }
> = {
  read_screenshot: { icon: Camera, label: "Screenshot", color: "text-cyan-400" },
  push_widget: { icon: Layout, label: "Widget", color: "text-emerald-400" },
  run_browser_task: { icon: Globe, label: "Browser", color: "text-sky-400" },
  run_bash: { icon: Terminal, label: "Bash", color: "text-amber-400" },
  web_search: { icon: Search, label: "Web Search", color: "text-blue-400" },
  read_transcript: { icon: Mic, label: "Transcript", color: "text-pink-400" },
};

function pretty(value: unknown): string {
  if (typeof value === "string") return value;
  if (value == null) return "";
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function toolResultStatus(call: ToolCall): "error" | "ok" | null {
  const result = call.result;
  if (result == null) return null;
  if (typeof result === "string") return null;
  if (typeof result !== "object") return null;

  const record = result as Record<string, unknown>;
  if (record.ok === false) return "error";
  if (typeof record.error === "string" && record.error.trim().length > 0) return "error";
  if (record.ok === true) return "ok";
  return null;
}

function ScreenshotCard({ call }: { call: ToolCall }) {
  const device = (call.input.device as string) || "unknown";
  const base64 = call.screenshot_base64;

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 text-xs text-zinc-400">
        <Image className="h-3 w-3 text-cyan-400" />
        <span>
          Screenshot from <span className="font-mono text-cyan-300">{device}</span>
        </span>
      </div>
      {base64 ? (
        <div className="rounded-lg border border-zinc-700 overflow-hidden bg-zinc-900">
          <img
            src={`data:image/png;base64,${base64}`}
            alt={`Screenshot from ${device}`}
            className="w-full max-h-[400px] object-contain"
          />
        </div>
      ) : (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-6 text-center">
          <Camera className="h-8 w-8 text-zinc-700 mx-auto mb-2" />
          <p className="text-xs text-zinc-600">Screenshot captured (preview not available)</p>
        </div>
      )}
    </div>
  );
}

function WidgetCard({ call }: { call: ToolCall }) {
  const html = call.widget_html || (call.input.html as string) || "";
  const spec = call.widget_spec || {
    title: (call.input.title as string) || "Widget",
    kind: (call.input.kind as string) || "html",
    width: (call.input.width as number) || 400,
    height: (call.input.height as number) || 300,
    html,
    css: call.input.css as string,
    target_device: (call.input.target_device as string) || (call.input.device_id as string),
  };

  return <WidgetPreview spec={spec} html={html} />;
}

function BashCard({ call }: { call: ToolCall }) {
  const command = (call.input.command as string) || "";
  const result =
    typeof call.result === "string"
      ? call.result
      : JSON.stringify(call.result, null, 2);

  return (
    <div className="space-y-2">
      <div className="rounded-lg border border-zinc-700 bg-zinc-900 overflow-hidden">
        <div className="px-3 py-2 bg-zinc-800 border-b border-zinc-700 flex items-center gap-2">
          <div className="flex gap-1.5">
            <div className="w-2.5 h-2.5 rounded-full bg-red-500/60" />
            <div className="w-2.5 h-2.5 rounded-full bg-yellow-500/60" />
            <div className="w-2.5 h-2.5 rounded-full bg-green-500/60" />
          </div>
          <span className="text-[10px] text-zinc-500 font-mono ml-1">terminal</span>
        </div>
        <div className="p-3">
          <div className="terminal-output text-amber-300">
            <span className="text-zinc-600">$ </span>
            {command}
          </div>
          {result && (
            <div className="terminal-output text-zinc-400 mt-2 border-t border-zinc-800 pt-2">
              {result}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function SearchCard({ call }: { call: ToolCall }) {
  const query = (call.input.query as string) || "";
  const result =
    typeof call.result === "string"
      ? call.result
      : JSON.stringify(call.result, null, 2);

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2">
        <Globe className="h-4 w-4 text-blue-400" />
        <span className="text-sm text-zinc-200">{query}</span>
      </div>
      {result && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-3">
          <pre className="terminal-output text-zinc-400 text-xs whitespace-pre-wrap">
            {result}
          </pre>
        </div>
      )}
    </div>
  );
}

function TranscriptCard({ call }: { call: ToolCall }) {
  const result =
    typeof call.result === "string"
      ? call.result
      : JSON.stringify(call.result, null, 2);

  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-3">
      <div className="flex items-center gap-2 mb-2">
        <Mic className="h-3.5 w-3.5 text-pink-400" />
        <span className="text-xs text-pink-400 font-medium">Transcript</span>
      </div>
      <p className="text-sm text-zinc-300 whitespace-pre-wrap">{result}</p>
    </div>
  );
}

function GenericCard({ call }: { call: ToolCall }) {
  const [showInput, setShowInput] = useState(false);

  return (
    <div className="space-y-2">
      <button
        onClick={() => setShowInput(!showInput)}
        className="flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-400"
      >
        {showInput ? <ChevronDown className="h-3 w-3" /> : <ChevronRight className="h-3 w-3" />}
        Input
      </button>
      {showInput && (
        <pre className="terminal-output text-zinc-400 text-xs rounded-lg bg-zinc-900 p-3 border border-zinc-800">
          {JSON.stringify(call.input, null, 2)}
        </pre>
      )}
      {call.result != null && (
        <pre className="terminal-output text-zinc-400 text-xs rounded-lg bg-zinc-900 p-3 border border-zinc-800">
          {typeof call.result === "string"
            ? call.result
            : JSON.stringify(call.result, null, 2)}
        </pre>
      )}
    </div>
  );
}

function ExactArgsCard({ call }: { call: ToolCall }) {
  const [showNormalizedInput, setShowNormalizedInput] = useState(false);
  const [showExactArgs, setShowExactArgs] = useState(true);
  const [showRawPayload, setShowRawPayload] = useState(false);

  const raw = call.raw;
  const rawArgs =
    raw && Object.prototype.hasOwnProperty.call(raw, "arguments")
      ? raw.arguments
      : undefined;
  const rawInput =
    raw && Object.prototype.hasOwnProperty.call(raw, "input")
      ? raw.input
      : undefined;
  const exactArgs = rawArgs ?? rawInput ?? call.input;
  const exactArgsText = pretty(exactArgs);

  return (
    <div className="space-y-2 border-t border-zinc-800 pt-3">
      <button
        onClick={() => setShowExactArgs((v) => !v)}
        className="flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-400"
      >
        {showExactArgs ? <ChevronDown className="h-3 w-3" /> : <ChevronRight className="h-3 w-3" />}
        Exact Args
      </button>
      {showExactArgs && (
        <pre className="terminal-output text-zinc-300 text-xs rounded-lg bg-zinc-900 p-3 border border-zinc-800 whitespace-pre-wrap">
          {exactArgsText || "(empty)"}
        </pre>
      )}

      <button
        onClick={() => setShowNormalizedInput((v) => !v)}
        className="flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-400"
      >
        {showNormalizedInput ? (
          <ChevronDown className="h-3 w-3" />
        ) : (
          <ChevronRight className="h-3 w-3" />
        )}
        Normalized Input
      </button>
      {showNormalizedInput && (
        <pre className="terminal-output text-zinc-400 text-xs rounded-lg bg-zinc-900 p-3 border border-zinc-800 whitespace-pre-wrap">
          {pretty(call.input) || "(empty)"}
        </pre>
      )}

      {raw && (
        <>
          <button
            onClick={() => setShowRawPayload((v) => !v)}
            className="flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-400"
          >
            {showRawPayload ? (
              <ChevronDown className="h-3 w-3" />
            ) : (
              <ChevronRight className="h-3 w-3" />
            )}
            Raw Payload
          </button>
          {showRawPayload && (
            <pre className="terminal-output text-zinc-500 text-xs rounded-lg bg-zinc-950 p-3 border border-zinc-800 whitespace-pre-wrap">
              {pretty(raw)}
            </pre>
          )}
        </>
      )}
    </div>
  );
}

function ToolCallSection({ call, index }: { call: ToolCall; index: number }) {
  const [collapsed, setCollapsed] = useState(false);
  const status = toolResultStatus(call);
  const meta = toolMeta[call.name] || {
    icon: Terminal,
    label: call.name,
    color: "text-zinc-400",
  };
  const Icon = meta.icon;

  function renderContent() {
    switch (call.name) {
      case "read_screenshot":
        return <ScreenshotCard call={call} />;
      case "push_widget":
        return <WidgetCard call={call} />;
      case "run_bash":
        return <BashCard call={call} />;
      case "web_search":
        return <SearchCard call={call} />;
      case "read_transcript":
        return <TranscriptCard call={call} />;
      default:
        return <GenericCard call={call} />;
    }
  }

  return (
    <div className="rounded-lg border border-zinc-800 overflow-hidden">
      <button
        onClick={() => setCollapsed(!collapsed)}
        className="w-full flex items-center justify-between px-3 py-2.5 bg-zinc-900/80 hover:bg-zinc-900 transition-colors"
      >
        <div className="flex items-center gap-2">
          <Icon className={cn("h-4 w-4", meta.color)} />
          <span className="text-sm font-medium text-zinc-200">{meta.label}</span>
          <span className="text-[10px] font-mono text-zinc-600">#{index + 1}</span>
        </div>
        <div className="flex items-center gap-2">
          {call.duration_ms && call.duration_ms > 0 && (
            <span className="flex items-center gap-1 text-[10px] text-zinc-600 font-mono">
              <Clock className="h-3 w-3" />
              {formatDuration(call.duration_ms)}
            </span>
          )}
          {status === "error" && (
            <span className="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded bg-red-500/20 text-red-300 border border-red-500/40">
              error
            </span>
          )}
          {status === "ok" && (
            <span className="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-300 border border-emerald-500/40">
              ok
            </span>
          )}
          {collapsed ? (
            <ChevronRight className="h-4 w-4 text-zinc-600" />
          ) : (
            <ChevronDown className="h-4 w-4 text-zinc-600" />
          )}
        </div>
      </button>
      {!collapsed && (
        <div className="p-3 space-y-3">
          {renderContent()}
          <ExactArgsCard call={call} />
        </div>
      )}
    </div>
  );
}

export function ToolPanel({ trajectory, selectedStep }: Props) {
  const step = trajectory.steps[selectedStep];

  if (!step || step.type !== "agent_turn" || step.tool_calls.length === 0) {
    const label =
      step?.type === "user_message"
        ? "User message — no tool calls"
        : step?.type === "session_message"
          ? `${step.role || "Session"} message — no tool calls`
        : step?.type === "final_response"
          ? "Final response — no tool calls"
          : "Select an agent step to view tool calls";

    return (
      <div className="h-full flex items-center justify-center p-4">
        <div className="text-center">
          <div className="inline-flex rounded-full bg-zinc-900 p-3 mb-3">
            <Terminal className="h-6 w-6 text-zinc-700" />
          </div>
          <p className="text-xs text-zinc-600">{label}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full overflow-y-auto p-4 space-y-3">
      <h3 className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3 sticky top-0 bg-zinc-950 py-1 z-10">
        Tool Calls ({step.tool_calls.length})
      </h3>
      {step.tool_calls.map((tc, i) => (
        <ToolCallSection key={tc.id} call={tc} index={i} />
      ))}
    </div>
  );
}

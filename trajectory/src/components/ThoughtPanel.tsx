"use client";

import { TrajectoryFile, TrajectoryStep } from "@/lib/types";
import { cn } from "@/lib/utils";
import {
  MessageSquare,
  Brain,
  CheckCircle2,
  Camera,
  Layout,
  Terminal,
  Search,
  Mic,
  ScrollText,
  Code2,
} from "lucide-react";

interface Props {
  trajectory: TrajectoryFile;
  selectedStep: number;
}

const toolIcons: Record<string, typeof Camera> = {
  read_screenshot: Camera,
  push_widget: Layout,
  run_bash: Terminal,
  web_search: Search,
  read_transcript: Mic,
};

function StepBubble({
  step,
  isActive,
}: {
  step: TrajectoryStep;
  isActive: boolean;
}) {
  if (step.type === "user_message") {
    return (
      <div
        className={cn(
          "rounded-lg border p-4 transition-all",
          isActive
            ? "border-blue-500/40 bg-blue-500/10"
            : "border-zinc-800/50 bg-zinc-900/30 opacity-60"
        )}
      >
        <div className="flex items-center gap-2 mb-2">
          <MessageSquare className="h-3.5 w-3.5 text-blue-400" />
          <span className="text-xs font-medium text-blue-400">User</span>
        </div>
        <p className="text-sm text-zinc-200 whitespace-pre-wrap leading-relaxed">
          {step.content}
        </p>
        {step.transcripts && step.transcripts.length > 0 && (
          <div className="mt-3 flex items-start gap-2 text-xs text-zinc-500 border-t border-zinc-800 pt-2">
            <Mic className="h-3 w-3 mt-0.5 flex-shrink-0" />
            <span>{step.transcripts.join(" ")}</span>
          </div>
        )}
      </div>
    );
  }

  if (step.type === "agent_turn") {
    return (
      <div
        className={cn(
          "rounded-lg border p-4 transition-all",
          isActive
            ? "border-violet-500/40 bg-violet-500/10"
            : "border-zinc-800/50 bg-zinc-900/30 opacity-60"
        )}
      >
        <div className="flex items-center gap-2 mb-2">
          <Brain className="h-3.5 w-3.5 text-violet-400" />
          <span className="text-xs font-medium text-violet-400">
            Agent Reasoning
          </span>
        </div>
        <p className="text-sm text-zinc-200 whitespace-pre-wrap leading-relaxed">
          {step.thought}
        </p>
        {/* Tool call summary */}
        {step.tool_calls.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-2 border-t border-zinc-800 pt-3">
            {step.tool_calls.map((tc) => {
              const Icon = toolIcons[tc.name] || Terminal;
              return (
                <div
                  key={tc.id}
                  className="flex items-center gap-1.5 rounded-md bg-zinc-800/80 px-2 py-1 text-xs text-zinc-400"
                >
                  <Icon className="h-3 w-3" />
                  <span className="font-mono">{tc.name}</span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    );
  }

  if (step.type === "session_message") {
    const label = step.role ? step.role.toUpperCase() : "MESSAGE";
    return (
      <div
        className={cn(
          "rounded-lg border p-4 transition-all",
          isActive
            ? "border-amber-500/40 bg-amber-500/10"
            : "border-zinc-800/50 bg-zinc-900/30 opacity-60"
        )}
      >
        <div className="flex items-center gap-2 mb-2">
          <ScrollText className="h-3.5 w-3.5 text-amber-400" />
          <span className="text-xs font-medium text-amber-400">{label}</span>
        </div>
        <p className="text-sm text-zinc-200 whitespace-pre-wrap leading-relaxed">
          {step.content || "(empty)"}
        </p>
        {step.raw_message && (
          <details className="mt-3 border-t border-zinc-800 pt-3">
            <summary className="cursor-pointer text-xs text-zinc-500 hover:text-zinc-400 flex items-center gap-1.5">
              <Code2 className="h-3 w-3" />
              Raw message
            </summary>
            <pre className="terminal-output mt-2 text-xs text-zinc-400 whitespace-pre-wrap rounded-md border border-zinc-800 bg-zinc-900/70 p-2">
              {JSON.stringify(step.raw_message, null, 2)}
            </pre>
          </details>
        )}
      </div>
    );
  }

  // final_response
  return (
    <div
      className={cn(
        "rounded-lg border p-4 transition-all",
        isActive
          ? "border-emerald-500/40 bg-emerald-500/10"
          : "border-zinc-800/50 bg-zinc-900/30 opacity-60"
      )}
    >
      <div className="flex items-center gap-2 mb-2">
        <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
        <span className="text-xs font-medium text-emerald-400">
          Final Response
        </span>
      </div>
      <p className="text-sm text-zinc-200 whitespace-pre-wrap leading-relaxed">
        {step.content}
      </p>
    </div>
  );
}

export function ThoughtPanel({ trajectory, selectedStep }: Props) {
  return (
    <div className="h-full overflow-y-auto p-4 space-y-3">
      <h3 className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3 sticky top-0 bg-zinc-950 py-1 z-10">
        Conversation
      </h3>
      {trajectory.steps.map((step, i) => (
        <div key={i} className={cn("animate-fade-in")} style={{ animationDelay: `${i * 50}ms` }}>
          <StepBubble step={step} isActive={i === selectedStep} />
        </div>
      ))}
    </div>
  );
}

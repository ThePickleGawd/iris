"use client";

import { useEffect, useRef } from "react";
import { TrajectoryStep } from "@/lib/types";
import { formatDuration } from "@/lib/parse-logs";
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
} from "lucide-react";

interface Props {
  steps: TrajectoryStep[];
  selectedStep: number;
  onSelectStep: (step: number) => void;
}

const toolIcons: Record<string, typeof Camera> = {
  read_screenshot: Camera,
  push_widget: Layout,
  run_bash: Terminal,
  web_search: Search,
  read_transcript: Mic,
};

function getStepColor(step: TrajectoryStep) {
  switch (step.type) {
    case "user_message":
      return { border: "border-blue-500/60", bg: "bg-blue-500", text: "text-blue-400" };
    case "agent_turn":
      return { border: "border-violet-500/60", bg: "bg-violet-500", text: "text-violet-400" };
    case "final_response":
      return { border: "border-emerald-500/60", bg: "bg-emerald-500", text: "text-emerald-400" };
    case "session_message":
      return { border: "border-amber-500/60", bg: "bg-amber-500", text: "text-amber-400" };
  }
}

function getStepLabel(step: TrajectoryStep) {
  switch (step.type) {
    case "user_message":
      return "User";
    case "agent_turn":
      return "Agent";
    case "final_response":
      return "Response";
    case "session_message":
      return step.role || "Message";
  }
}

function getStepIcon(step: TrajectoryStep) {
  switch (step.type) {
    case "user_message":
      return MessageSquare;
    case "agent_turn":
      return Brain;
    case "final_response":
      return CheckCircle2;
    case "session_message":
      return ScrollText;
  }
}

function getStepPreview(step: TrajectoryStep): string {
  switch (step.type) {
    case "user_message":
      return step.content.slice(0, 80);
    case "agent_turn":
      return step.thought.slice(0, 80);
    case "final_response":
      return step.content.slice(0, 80);
    case "session_message":
      return step.content.slice(0, 80);
  }
}

export function StepTimeline({ steps, selectedStep, onSelectStep }: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const cardRefs = useRef<(HTMLButtonElement | null)[]>([]);

  // Auto-scroll to keep selected step visible
  useEffect(() => {
    const card = cardRefs.current[selectedStep];
    if (card && scrollRef.current) {
      const container = scrollRef.current;
      const cardLeft = card.offsetLeft;
      const cardWidth = card.offsetWidth;
      const scrollLeft = container.scrollLeft;
      const containerWidth = container.clientWidth;

      if (cardLeft < scrollLeft + 20) {
        container.scrollTo({ left: cardLeft - 20, behavior: "smooth" });
      } else if (cardLeft + cardWidth > scrollLeft + containerWidth - 20) {
        container.scrollTo({
          left: cardLeft + cardWidth - containerWidth + 20,
          behavior: "smooth",
        });
      }
    }
  }, [selectedStep]);

  return (
    <div
      ref={scrollRef}
      className="timeline-scroll flex gap-3 overflow-x-auto px-4 py-3"
    >
      {steps.map((step, i) => {
        const color = getStepColor(step);
        const Icon = getStepIcon(step);
        const isActive = i === selectedStep;
        const toolNames =
          step.type === "agent_turn"
            ? [...new Set(step.tool_calls.map((tc) => tc.name))]
            : [];

        return (
          <button
            key={i}
            ref={(el) => { cardRefs.current[i] = el; }}
            onClick={() => onSelectStep(i)}
            className={cn(
              "flex-shrink-0 w-56 rounded-lg border p-3 text-left transition-all duration-200",
              isActive
                ? `${color.border} bg-zinc-800/80 pulse-glow`
                : "border-zinc-800 bg-zinc-900/50 hover:border-zinc-700 hover:bg-zinc-900"
            )}
          >
            {/* Header */}
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center gap-2">
                <div
                  className={cn(
                    "flex items-center justify-center w-6 h-6 rounded-full text-[10px] font-bold",
                    isActive ? `${color.bg} text-white` : "bg-zinc-800 text-zinc-400"
                  )}
                >
                  {i}
                </div>
                <span
                  className={cn(
                    "text-xs font-medium",
                    isActive ? color.text : "text-zinc-500"
                  )}
                >
                  {getStepLabel(step)}
                </span>
              </div>
              <Icon
                className={cn(
                  "h-3.5 w-3.5",
                  isActive ? color.text : "text-zinc-600"
                )}
              />
            </div>

            {/* Preview */}
            <p className="text-xs text-zinc-400 line-clamp-2 mb-2 leading-relaxed">
              {getStepPreview(step)}
            </p>

            {/* Tool badges + duration */}
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-1">
                {toolNames.map((name) => {
                  const TIcon = toolIcons[name] || Terminal;
                  return (
                    <div
                      key={name}
                      className="flex items-center justify-center w-5 h-5 rounded bg-zinc-800 text-zinc-500"
                      title={name}
                    >
                      <TIcon className="h-3 w-3" />
                    </div>
                  );
                })}
              </div>
              {step.type === "agent_turn" && step.duration_ms > 0 && (
                <span className="text-[10px] text-zinc-600 font-mono">
                  {formatDuration(step.duration_ms)}
                </span>
              )}
            </div>
          </button>
        );
      })}
    </div>
  );
}

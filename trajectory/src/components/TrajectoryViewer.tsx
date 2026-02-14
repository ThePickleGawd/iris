"use client";

import { useState, useEffect, useCallback } from "react";
import { PanelGroup, Panel, PanelResizeHandle } from "react-resizable-panels";
import { StepTimeline } from "./StepTimeline";
import { ThoughtPanel } from "./ThoughtPanel";
import { ToolPanel } from "./ToolPanel";
import { TrajectoryFile } from "@/lib/types";
import { formatDuration } from "@/lib/parse-logs";
import {
  ArrowLeft,
  Clock,
  Wrench,
  Camera,
  Layout,
  Terminal,
  Search,
  Cpu,
  Layers,
} from "lucide-react";

interface Props {
  trajectory: TrajectoryFile;
  onBack: () => void;
}

function StatBadge({
  icon: Icon,
  label,
  value,
  color,
}: {
  icon: typeof Clock;
  label: string;
  value: string | number;
  color: string;
}) {
  if (value === 0 || value === "0") return null;
  return (
    <div className="flex items-center gap-2 rounded-lg border border-zinc-800 bg-zinc-900/50 px-3 py-2">
      <Icon className={`h-4 w-4 ${color}`} />
      <div>
        <p className="text-sm font-semibold text-zinc-100">{value}</p>
        <p className="text-[10px] text-zinc-500">{label}</p>
      </div>
    </div>
  );
}

export function TrajectoryViewer({ trajectory, onBack }: Props) {
  const [selectedStep, setSelectedStep] = useState(0);

  // Keyboard navigation
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft" || e.key === "k") {
        setSelectedStep((s) => Math.max(0, s - 1));
      } else if (e.key === "ArrowRight" || e.key === "j") {
        setSelectedStep((s) =>
          Math.min(trajectory.steps.length - 1, s + 1)
        );
      } else if (e.key === "Escape") {
        onBack();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [trajectory.steps.length, onBack]);

  const { computed, metadata } = trajectory;

  return (
    <div className="h-screen flex flex-col bg-zinc-950 text-zinc-100">
      {/* Header */}
      <div className="flex-shrink-0 border-b border-zinc-800 px-4 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={onBack}
              className="rounded-lg p-1.5 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200"
            >
              <ArrowLeft className="h-5 w-5" />
            </button>
            <div>
              <h1 className="text-sm font-semibold text-zinc-100 truncate max-w-xl">
                {metadata.task}
              </h1>
              <div className="flex items-center gap-3 mt-0.5 text-[11px] text-zinc-500">
                <span className="flex items-center gap-1">
                  <Cpu className="h-3 w-3" />
                  {metadata.agent}
                </span>
                <span className="font-mono">{metadata.model}</span>
                <span>{new Date(metadata.started_at).toLocaleString()}</span>
              </div>
            </div>
          </div>

          {/* Stats */}
          <div className="hidden md:flex items-center gap-2">
            <StatBadge
              icon={Layers}
              label="Steps"
              value={computed.totalSteps}
              color="text-violet-400"
            />
            <StatBadge
              icon={Wrench}
              label="Tool Calls"
              value={computed.totalToolCalls}
              color="text-amber-400"
            />
            <StatBadge
              icon={Camera}
              label="Screenshots"
              value={computed.screenshotCount}
              color="text-cyan-400"
            />
            <StatBadge
              icon={Layout}
              label="Widgets"
              value={computed.widgetCount}
              color="text-emerald-400"
            />
            <StatBadge
              icon={Clock}
              label="Duration"
              value={formatDuration(computed.totalDurationMs)}
              color="text-zinc-400"
            />
          </div>
        </div>
      </div>

      {/* Step Timeline */}
      <div className="flex-shrink-0 border-b border-zinc-800 bg-zinc-950/50">
        <StepTimeline
          steps={trajectory.steps}
          selectedStep={selectedStep}
          onSelectStep={setSelectedStep}
        />
      </div>

      {/* Split Panels */}
      <PanelGroup direction="horizontal" className="flex-1 min-h-0">
        <Panel defaultSize={45} minSize={25}>
          <ThoughtPanel
            trajectory={trajectory}
            selectedStep={selectedStep}
          />
        </Panel>
        <PanelResizeHandle className="w-1.5 bg-zinc-900 resize-handle" />
        <Panel defaultSize={55} minSize={25}>
          <ToolPanel trajectory={trajectory} selectedStep={selectedStep} />
        </Panel>
      </PanelGroup>

      {/* Footer */}
      <div className="flex-shrink-0 border-t border-zinc-800 px-4 py-1.5 text-[10px] text-zinc-600 flex items-center justify-between">
        <span>
          Step {selectedStep + 1} of {trajectory.steps.length}
        </span>
        <span className="flex items-center gap-3">
          <span>
            <kbd className="px-1 py-0.5 rounded bg-zinc-900 border border-zinc-800 text-zinc-500">
              j
            </kbd>{" "}
            /{" "}
            <kbd className="px-1 py-0.5 rounded bg-zinc-900 border border-zinc-800 text-zinc-500">
              k
            </kbd>{" "}
            navigate
          </span>
          <span>
            <kbd className="px-1 py-0.5 rounded bg-zinc-900 border border-zinc-800 text-zinc-500">
              esc
            </kbd>{" "}
            back
          </span>
        </span>
      </div>
    </div>
  );
}

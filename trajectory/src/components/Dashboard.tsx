"use client";

import { useState, useCallback, useEffect } from "react";
import { FileUploader } from "./FileUploader";
import { TrajectoryViewer } from "./TrajectoryViewer";
import { parseTrajectoryFile, formatDuration } from "@/lib/parse-logs";
import { TrajectoryFile } from "@/lib/types";
import {
  Eye,
  Cpu,
  Clock,
  Wrench,
  Camera,
  Layout,
  ChevronRight,
} from "lucide-react";

export function Dashboard() {
  const [trajectories, setTrajectories] = useState<TrajectoryFile[]>([]);
  const [selected, setSelected] = useState<TrajectoryFile | null>(null);
  const [demoFiles, setDemoFiles] = useState<TrajectoryFile[]>([]);

  // Load trajectories from agents/log/ and public/demo/
  useEffect(() => {
    async function loadLogs() {
      const loaded: TrajectoryFile[] = [];

      // Load from agents/log/ via API
      try {
        const listResp = await fetch("/api/logs");
        if (listResp.ok) {
          const { files } = await listResp.json();
          for (const file of files as string[]) {
            try {
              const resp = await fetch(`/api/logs/${file}`);
              if (resp.ok) {
                const content = await resp.text();
                loaded.push(parseTrajectoryFile(file, content));
              }
            } catch {
              // skip unreadable files
            }
          }
        }
      } catch {
        // API not available
      }

      // Fallback: load demo from public/
      if (loaded.length === 0) {
        try {
          const resp = await fetch("/demo/example-trajectory.jsonl");
          if (resp.ok) {
            const content = await resp.text();
            loaded.push(
              parseTrajectoryFile("example-trajectory.jsonl", content)
            );
          }
        } catch {
          // No demo files
        }
      }

      setDemoFiles(loaded);
    }
    loadLogs();
  }, []);

  const handleFileLoaded = useCallback((name: string, content: string) => {
    const traj = parseTrajectoryFile(name, content);
    setTrajectories((prev) => [...prev, traj]);
    setSelected(traj);
  }, []);

  if (selected) {
    return (
      <TrajectoryViewer
        trajectory={selected}
        onBack={() => setSelected(null)}
      />
    );
  }

  const allTrajectories = [...demoFiles, ...trajectories];

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      {/* Header */}
      <div className="border-b border-zinc-800 bg-zinc-950/80 backdrop-blur-sm">
        <div className="mx-auto max-w-5xl px-6 py-8">
          <div className="flex items-center gap-3 mb-2">
            <div className="rounded-lg bg-violet-600/20 p-2">
              <Eye className="h-6 w-6 text-violet-400" />
            </div>
            <h1 className="text-2xl font-semibold tracking-tight">
              Iris Trajectory Visualizer
            </h1>
          </div>
          <p className="text-sm text-zinc-400 ml-[52px]">
            Explore agent trajectories — screenshots, widgets, reasoning, and
            tool calls
          </p>
        </div>
      </div>

      <div className="mx-auto max-w-5xl px-6 py-8 space-y-8">
        {/* Upload */}
        <FileUploader onFileLoaded={handleFileLoaded} />

        {/* Trajectories */}
        {allTrajectories.length > 0 && (
          <div>
            <h2 className="text-sm font-medium text-zinc-400 uppercase tracking-wider mb-4">
              Trajectories
            </h2>
            <div className="grid gap-3">
              {allTrajectories.map((traj, i) => (
                <button
                  key={`${traj.fileName}-${i}`}
                  onClick={() => setSelected(traj)}
                  className="group w-full text-left rounded-xl border border-zinc-800 bg-zinc-900/50 p-5 hover:border-violet-600/50 hover:bg-zinc-900 transition-all duration-200"
                >
                  <div className="flex items-start justify-between">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-1">
                        <span className="text-xs font-mono text-zinc-500">
                          {traj.fileName}
                        </span>
                        {demoFiles.includes(traj) && (
                          <span className="text-[10px] font-medium uppercase tracking-wider text-violet-400 bg-violet-500/10 px-1.5 py-0.5 rounded">
                            demo
                          </span>
                        )}
                      </div>
                      <p className="text-sm font-medium text-zinc-100 truncate">
                        {traj.metadata.task}
                      </p>
                      <div className="flex items-center gap-4 mt-3 text-xs text-zinc-500">
                        <span className="flex items-center gap-1">
                          <Cpu className="h-3 w-3" />
                          {traj.metadata.agent}
                        </span>
                        <span className="flex items-center gap-1">
                          <Wrench className="h-3 w-3" />
                          {traj.computed.totalToolCalls} tools
                        </span>
                        {traj.computed.screenshotCount > 0 && (
                          <span className="flex items-center gap-1">
                            <Camera className="h-3 w-3" />
                            {traj.computed.screenshotCount}
                          </span>
                        )}
                        {traj.computed.widgetCount > 0 && (
                          <span className="flex items-center gap-1">
                            <Layout className="h-3 w-3" />
                            {traj.computed.widgetCount}
                          </span>
                        )}
                        <span className="flex items-center gap-1">
                          <Clock className="h-3 w-3" />
                          {formatDuration(traj.computed.totalDurationMs)}
                        </span>
                      </div>
                    </div>
                    <ChevronRight className="h-5 w-5 text-zinc-600 group-hover:text-violet-400 transition-colors mt-1" />
                  </div>
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Empty state */}
        {allTrajectories.length === 0 && (
          <div className="text-center py-16">
            <div className="inline-flex rounded-full bg-zinc-900 p-4 mb-4">
              <Eye className="h-8 w-8 text-zinc-600" />
            </div>
            <p className="text-sm text-zinc-500">
              Upload a trajectory .jsonl file to get started
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

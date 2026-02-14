"use client";

import { useRef, useEffect, useState } from "react";
import { WidgetSpec } from "@/lib/types";
import { Layout, Maximize2, Minimize2, Tablet } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  spec: WidgetSpec;
  html: string;
}

export function WidgetPreview({ spec, html }: Props) {
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [expanded, setExpanded] = useState(false);

  const width = spec.width || 400;
  const height = spec.height || 300;

  // Build full HTML document for the iframe
  const doc = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #ffffff;
      color: #1a1a1a;
    }
    ${spec.css || ""}
  </style>
</head>
<body>${html}</body>
</html>`;

  useEffect(() => {
    const iframe = iframeRef.current;
    if (!iframe) return;
    const blob = new Blob([doc], { type: "text/html" });
    iframe.src = URL.createObjectURL(blob);
    return () => URL.revokeObjectURL(iframe.src);
  }, [doc]);

  return (
    <div className="rounded-lg border border-zinc-700 overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2 bg-zinc-800 border-b border-zinc-700">
        <div className="flex items-center gap-2">
          <Layout className="h-3.5 w-3.5 text-emerald-400" />
          <span className="text-xs font-medium text-zinc-300">
            {spec.title || "Widget"}
          </span>
          {spec.kind && (
            <span className="text-[10px] font-mono text-zinc-500 bg-zinc-900 px-1.5 py-0.5 rounded">
              {spec.kind}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {spec.target_device && (
            <span className="flex items-center gap-1 text-[10px] text-zinc-500">
              <Tablet className="h-3 w-3" />
              {spec.target_device}
            </span>
          )}
          <button
            onClick={() => setExpanded(!expanded)}
            className="p-1 rounded hover:bg-zinc-700 text-zinc-500 hover:text-zinc-300 transition-colors"
          >
            {expanded ? (
              <Minimize2 className="h-3.5 w-3.5" />
            ) : (
              <Maximize2 className="h-3.5 w-3.5" />
            )}
          </button>
        </div>
      </div>

      {/* iframe */}
      <div
        className={cn(
          "widget-frame bg-white transition-all duration-300",
          expanded ? "h-[500px]" : "h-[280px]"
        )}
        style={{ maxWidth: expanded ? "100%" : `${width}px` }}
      >
        <iframe
          ref={iframeRef}
          className="w-full h-full border-0"
          sandbox="allow-scripts"
          title={spec.title || "Widget preview"}
        />
      </div>

      {/* Dimensions */}
      <div className="px-3 py-1.5 bg-zinc-900 text-[10px] text-zinc-600 font-mono">
        {width} x {height}
      </div>
    </div>
  );
}

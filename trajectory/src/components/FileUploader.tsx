"use client";

import { useCallback, useState, useRef } from "react";
import { Upload, FileText } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  onFileLoaded: (fileName: string, content: string) => void;
}

export function FileUploader({ onFileLoaded }: Props) {
  const [isDragging, setIsDragging] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const handleFile = useCallback(
    (file: File) => {
      file.text().then((content) => {
        onFileLoaded(file.name, content);
      });
    },
    [onFileLoaded]
  );

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setIsDragging(false);
      const file = e.dataTransfer.files[0];
      if (file?.name.endsWith(".jsonl")) handleFile(file);
    },
    [handleFile]
  );

  const onDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  }, []);

  const onDragLeave = useCallback(() => setIsDragging(false), []);

  const onChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (file) handleFile(file);
    },
    [handleFile]
  );

  return (
    <div
      onDrop={onDrop}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onClick={() => inputRef.current?.click()}
      className={cn(
        "relative cursor-pointer rounded-xl border-2 border-dashed p-8",
        "flex flex-col items-center justify-center gap-3",
        "transition-all duration-200",
        isDragging
          ? "border-violet-500 bg-violet-500/10"
          : "border-zinc-700 bg-zinc-900/50 hover:border-zinc-500 hover:bg-zinc-900"
      )}
    >
      <input
        ref={inputRef}
        type="file"
        accept=".jsonl"
        onChange={onChange}
        className="hidden"
      />
      <div
        className={cn(
          "rounded-full p-3",
          isDragging ? "bg-violet-500/20" : "bg-zinc-800"
        )}
      >
        {isDragging ? (
          <FileText className="h-6 w-6 text-violet-400" />
        ) : (
          <Upload className="h-6 w-6 text-zinc-400" />
        )}
      </div>
      <div className="text-center">
        <p className="text-sm font-medium text-zinc-200">
          {isDragging ? "Drop trajectory file" : "Drop a .jsonl trajectory file here"}
        </p>
        <p className="mt-1 text-xs text-zinc-500">or click to browse</p>
      </div>
    </div>
  );
}

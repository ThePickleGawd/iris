import { readdir, readFile, stat } from "fs/promises";
import { basename, delimiter, isAbsolute, join, relative, resolve } from "path";

const LOG_FILE_EXT = ".jsonl";

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

function configuredLogDirs(): string[] {
  const raw = process.env.TRAJECTORY_LOG_DIRS || process.env.AGENT_LOG_DIR || "";
  if (!raw.trim()) return [];

  return raw
    .split(/[\n,]/)
    .flatMap((chunk) => chunk.split(delimiter))
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => resolve(process.cwd(), value));
}

function defaultLogDirs(): string[] {
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

function allLogDirs(): string[] {
  return [...new Set([...configuredLogDirs(), ...defaultLogDirs()])];
}

function isInsideDir(path: string, dir: string): boolean {
  const rel = relative(dir, path);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

function isAllowedLogPath(path: string): boolean {
  if (!path.endsWith(LOG_FILE_EXT)) return false;
  return allLogDirs().some((dir) => isInsideDir(path, dir));
}

export async function listTrajectoryLogs(): Promise<TrajectoryLogEntry[]> {
  const cwd = process.cwd();
  const entries: TrajectoryLogEntry[] = [];

  for (const dir of allLogDirs()) {
    let files: string[] = [];
    try {
      const dirEntries = await readdir(dir, { withFileTypes: true });
      files = dirEntries
        .filter((entry) => entry.isFile() && entry.name.endsWith(LOG_FILE_EXT))
        .map((entry) => entry.name);
    } catch {
      continue;
    }

    const rows = await Promise.all(
      files.map(async (fileName): Promise<TrajectoryLogEntry> => {
        const path = resolve(dir, fileName);
        let modifiedAt = 0;
        try {
          modifiedAt = (await stat(path)).mtimeMs;
        } catch {
          // Keep 0 for unknown mtimes.
        }

        const source = relative(cwd, dir) || ".";
        return {
          id: encodePath(path),
          fileName,
          source,
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
  if (!fileName.endsWith(LOG_FILE_EXT) || basename(fileName) !== fileName) {
    return null;
  }

  for (const dir of allLogDirs()) {
    try {
      return await readFile(join(dir, fileName), "utf-8");
    } catch {
      // Try next directory.
    }
  }
  return null;
}

async function readByEncodedPath(encodedPath: string): Promise<string | null> {
  const decoded = decodePath(encodedPath);
  if (!decoded) return null;

  const path = resolve(decoded);
  if (!isAllowedLogPath(path)) return null;

  try {
    return await readFile(path, "utf-8");
  } catch {
    return null;
  }
}

export async function readTrajectoryLog(idOrFileName: string): Promise<string | null> {
  const byId = await readByEncodedPath(idOrFileName);
  if (byId !== null) return byId;
  return readByLegacyFileName(idOrFileName);
}

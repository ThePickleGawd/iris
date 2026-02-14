import { NextResponse } from "next/server";
import { readdir } from "fs/promises";
import { join } from "path";

const LOG_DIR = join(process.cwd(), "..", "agents", "log");

export async function GET() {
  try {
    const files = await readdir(LOG_DIR);
    const jsonlFiles = files
      .filter((f) => f.endsWith(".jsonl"))
      .sort()
      .reverse(); // newest first
    return NextResponse.json({ files: jsonlFiles });
  } catch {
    return NextResponse.json({ files: [] });
  }
}

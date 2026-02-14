import { NextResponse } from "next/server";
import { readFile } from "fs/promises";
import { join } from "path";

const LOG_DIR = join(process.cwd(), "..", "agents", "log");

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ filename: string }> }
) {
  const { filename } = await params;

  // Prevent path traversal
  if (filename.includes("..") || filename.includes("/")) {
    return NextResponse.json({ error: "Invalid filename" }, { status: 400 });
  }

  try {
    const content = await readFile(join(LOG_DIR, filename), "utf-8");
    return new NextResponse(content, {
      headers: { "Content-Type": "text/plain" },
    });
  } catch {
    return NextResponse.json({ error: "File not found" }, { status: 404 });
  }
}

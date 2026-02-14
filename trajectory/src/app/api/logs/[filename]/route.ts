import { NextResponse } from "next/server";
import { readTrajectoryLog } from "../_log-sources";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ filename: string }> }
) {
  const { filename } = await params;
  const content = await readTrajectoryLog(filename);
  if (content === null) {
    return NextResponse.json({ error: "File not found" }, { status: 404 });
  }

  return new NextResponse(content, {
    headers: { "Content-Type": "text/plain" },
  });
}

import { NextResponse } from "next/server";
import { listTrajectoryLogs } from "./_log-sources";

export async function GET() {
  try {
    const entries = await listTrajectoryLogs();
    return NextResponse.json({
      // `files` is kept for backwards compatibility.
      files: entries.map((entry) => entry.fileName),
      entries,
    });
  } catch {
    return NextResponse.json({ files: [], entries: [] });
  }
}

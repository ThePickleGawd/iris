// ── Trajectory JSONL schema ──────────────────────────────────────────

export interface TrajectoryMetadata {
  type: "metadata";
  session_id: string;
  agent: string;
  model: string;
  started_at: string;
  ended_at?: string;
  task: string;
  devices?: string[];
  system_prompt?: string;
  session_metadata?: Record<string, unknown>;
}

export interface Screenshot {
  device: string;
  base64: string;
  captured_at?: string;
}

export interface WidgetSpec {
  id?: string;
  title?: string;
  kind?: string;
  width?: number;
  height?: number;
  html: string;
  css?: string;
  target_device?: string;
}

export interface ToolCall {
  id: string;
  name: string;
  input: Record<string, unknown>;
  result: unknown;
  screenshot_base64?: string;
  widget_html?: string;
  widget_spec?: WidgetSpec;
  duration_ms?: number;
  raw?: Record<string, unknown>;
}

export interface UserMessage {
  type: "user_message";
  step: number;
  timestamp: string;
  content: string;
  role?: string;
  message_id?: string;
  source?: string;
  device_id?: string;
  screenshots?: Screenshot[];
  transcripts?: string[];
  raw_message?: Record<string, unknown>;
}

export interface AgentTurn {
  type: "agent_turn";
  step: number;
  timestamp: string;
  thought: string;
  role?: string;
  message_id?: string;
  source?: string;
  device_id?: string;
  tool_calls: ToolCall[];
  duration_ms: number;
  raw_message?: Record<string, unknown>;
}

export interface FinalResponse {
  type: "final_response";
  step: number;
  timestamp: string;
  content: string;
  total_duration_ms: number;
  role?: string;
  message_id?: string;
  source?: string;
  device_id?: string;
  raw_message?: Record<string, unknown>;
}

export interface SessionMessage {
  type: "session_message";
  step: number;
  timestamp: string;
  role: string;
  content: string;
  message_id?: string;
  source?: string;
  device_id?: string;
  raw_message?: Record<string, unknown>;
}

export type TrajectoryStep = UserMessage | AgentTurn | FinalResponse | SessionMessage;

export interface ComputedStats {
  totalSteps: number;
  totalToolCalls: number;
  screenshotCount: number;
  widgetCount: number;
  bashCount: number;
  searchCount: number;
  totalDurationMs: number;
  toolBreakdown: Record<string, number>;
}

export interface TrajectoryFile {
  fileName: string;
  metadata: TrajectoryMetadata;
  steps: TrajectoryStep[];
  computed: ComputedStats;
}

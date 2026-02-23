import { EventEnvelope, SessionState, ToolDefinition } from "../../core/types.js";

export type ToolSideEffect = "read" | "write" | "execute";
export type ToolTarget = "client" | "server";

export interface ToolExecutionContext {
  session: SessionState;
  emit: (event: EventEnvelope) => void;
}

export interface ToolRegistration {
  definition: ToolDefinition;
  target: ToolTarget;
  sideEffect: ToolSideEffect;
  supportsIdempotency?: boolean;
  execute?: (
    context: ToolExecutionContext,
    args: Record<string, unknown>,
  ) => Promise<unknown>;
}

export interface ToolExecutionResult {
  ok: boolean;
  result?: unknown;
  error?: string;
  sideEffect: ToolSideEffect;
}

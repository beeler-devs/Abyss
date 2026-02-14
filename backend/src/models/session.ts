/**
 * Session and conversation models for DynamoDB persistence.
 */

// ─── Bedrock conversation message format ────────────────────────────────────

export interface BedrockMessage {
  role: 'user' | 'assistant';
  content: BedrockContentBlock[];
}

export type BedrockContentBlock =
  | { text: string }
  | { toolUse: { toolUseId: string; name: string; input: unknown } }
  | { toolResult: { toolUseId: string; content: Array<{ text: string }>; status?: 'success' | 'error' } };

// ─── Session stored in DynamoDB ─────────────────────────────────────────────

export interface SessionRecord {
  sessionId: string;
  conversation: BedrockMessage[];
  createdAt: string;  // ISO-8601
  updatedAt: string;  // ISO-8601
}

// ─── Connection mapping ─────────────────────────────────────────────────────

export interface ConnectionRecord {
  connectionId: string;
  sessionId: string;
  connectedAt: string;  // ISO-8601
}

// ─── Pending tool call state ────────────────────────────────────────────────

export interface PendingToolCall {
  sessionId: string;
  pendingCallId: string;
  pendingToolName: string;
  bedrockToolUseId: string;  // The Bedrock-assigned toolUseId
  createdAt: string;         // ISO-8601
  ttl: number;               // DynamoDB TTL (epoch seconds)
}

// ─── Constants ──────────────────────────────────────────────────────────────

/** Maximum number of conversation turns to keep (bounded growth). */
export const MAX_CONVERSATION_TURNS = 50;

/** TTL for pending tool calls (seconds). */
export const PENDING_TOOL_CALL_TTL = 300; // 5 minutes

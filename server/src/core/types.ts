export interface EventEnvelope {
  id: string;
  type: string;
  timestamp: string;
  sessionId: string;
  payload: Record<string, unknown>;
}

export interface ConversationTurn {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface PendingToolCall {
  callId: string;
  toolName: string;
  emittedAt: string;
}

export interface SessionState {
  sessionId: string;
  githubToken?: string;
  history: ConversationTurn[];
  pendingToolCalls: Map<string, PendingToolCall>;
  recentTranscriptTrace: string[];
  transcriptCount: number;
}

export interface ModelResponse {
  fullText: string;
  chunks: AsyncIterable<string>;
}

export interface GenerateOptions {
  githubToken?: string;
}

export interface ModelProvider {
  readonly name: string;
  generateResponse(conversation: ConversationTurn[], options?: GenerateOptions): Promise<ModelResponse>;
}

export interface EventEnvelope {
  id: string;
  type: string;
  timestamp: string;
  sessionId: string;
  payload: Record<string, unknown>;
}

export interface ToolDefinition {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface ToolCallRequest {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ConversationTurn {
  role: "user" | "assistant" | "system" | "tool";
  content: string | ToolCallRequest[];
  tool_use_id?: string;
  tool_name?: string;
}

export interface PendingToolCall {
  callId: string;
  toolName: string;
  emittedAt: string;
}

export interface SessionState {
  sessionId: string;
  history: ConversationTurn[];
  pendingToolCalls: Map<string, PendingToolCall>;
  toolResultResolvers: Map<
    string,
    (result: string | null, error: string | null) => void
  >;
  recentTranscriptTrace: string[];
  transcriptCount: number;
}

export interface ModelResponse {
  fullText: string;
  chunks: AsyncIterable<string>;
  toolCalls?: ToolCallRequest[];
}

export interface ModelProvider {
  readonly name: string;
  generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
  ): Promise<ModelResponse>;
}

export interface EventEnvelope {
  id: string;
  type: string;
  timestamp: string;
  sessionId: string;
  protocolVersion: number;
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
  toolArguments?: Record<string, unknown>;
}

export type CursorAgentMode = "code" | "computer_use" | "webqa";

export interface CursorAgentRunRecord {
  agentId: string;
  sessionId: string;
  createdAt: string;
  mode: CursorAgentMode;
  status?: string;
  prUrl?: string;
  runUrl?: string;
  branchName?: string;
  summary?: string;
  spawnCallId?: string;
  lastSeenConversationMessageId?: string;
}

export interface PendingCursorWebhookRecord {
  agentId: string;
  payload: Record<string, unknown>;
  receivedAt: string;
  expiresAtMs: number;
}

export interface PendingGmailSend {
  callId: string;
  originalToolCallId: string;
  type: "send" | "reply";
  to: string;
  cc?: string;
  subject: string;
  body: string;
  messageId?: string;
}

export interface PendingCalendarMutation {
  callId: string;
  originalToolCallId: string;
  type: "create" | "update" | "delete";
  summary: string;
  startTime?: string;
  endTime?: string;
  description?: string;
  location?: string;
  attendees?: string[];
  eventId?: string;
}

export interface SessionState {
  sessionId: string;
  githubToken?: string;
  gmailAccessToken?: string;
  gmailRefreshToken?: string;
  gmailTokenExpiresAt?: number;
  canvasAccessToken?: string;
  canvasBaseURL?: string;
  userPreferences?: Record<string, string>;
  canvasCourseContext?: string;
  history: ConversationTurn[];
  historySummary?: string;
  pendingToolCalls: Map<string, PendingToolCall>;
  toolResultResolvers: Map<
    string,
    (result: string | null, error: string | null) => void
  >;
  pendingGmailSends: Map<string, PendingGmailSend>;
  pendingCalendarMutations: Map<string, PendingCalendarMutation>;
  recentTranscriptTrace: string[];
  transcriptCount: number;
  activeBridgeCommandId?: string;
  activeBridgeDeviceId?: string;
  memoryUserKey?: string;
  memoryHydrated?: boolean;
  workingContext?: {
    repo?: string;
    branch?: string;
    prUrl?: string;
    lastGoal?: string;
    activeExecutor?: string;
  };
  /** True while Nova Sonic is actively streaming audio for this session. */
  isLiveSession?: boolean;
}

export interface BridgeToolExecutionRequest {
  callId: string;
  sessionId: string;
  toolName: string;
  args: Record<string, unknown>;
  timeoutMs: number;
}

export interface BridgeToolExecutionResult {
  result: string | null;
  error: string | null;
}

export type BridgeToolExecutor = (
  request: BridgeToolExecutionRequest,
  emit: (event: EventEnvelope) => void,
) => Promise<BridgeToolExecutionResult>;

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
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
    modelOverride?: string,
  ): Promise<ModelResponse>;
}

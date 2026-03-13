import { EventEnvelope, ToolCallRequest, ToolDefinition } from "../core/types.js";

export interface VoiceToolExecutorResult {
  result: string | null;
  error: string | null;
}

export interface VoiceProviderContext {
  emit: (event: EventEnvelope) => void;
  listTools: (sessionId: string) => ToolDefinition[];
  executeTool?: (
    sessionId: string,
    toolCall: ToolCallRequest,
    emit: (event: EventEnvelope) => void,
  ) => Promise<VoiceToolExecutorResult>;
}

export interface VoiceProvider {
  readonly name: string;
  startStream(sessionId: string, context: VoiceProviderContext): Promise<void>;
  appendAudioChunk(sessionId: string, base64Audio: string): Promise<void>;
  endStream(sessionId: string): Promise<void>;
  interrupt(sessionId: string): Promise<void>;
  closeSession(sessionId: string): Promise<void>;
}

/**
 * Amazon Bedrock ConverseStream integration.
 *
 * Calls the Bedrock Converse API with streaming, using the tool_call
 * bridging pattern: we define a single "tool_call" tool that the model
 * uses to request client-side tool execution.
 */
import { BedrockRuntimeClient, type ToolConfiguration } from '@aws-sdk/client-bedrock-runtime';
import { BedrockMessage } from '../models/session';
export declare function initBedrockClient(region?: string): void;
export declare function getBedrockClient(): BedrockRuntimeClient;
/** For testing injection. */
export declare function setBedrockClient(client: BedrockRuntimeClient): void;
export declare function getModelId(): string;
export declare const SYSTEM_PROMPT = "You are VoiceIDE, a helpful voice assistant. You operate exclusively through tool calls \u2014 never produce side effects directly.\n\nRULES:\n1. For EVERY response, you MUST use the tool_call tool to execute actions.\n2. To speak to the user, emit: tool_call with name=\"tts.speak\" and arguments={\"text\": \"your spoken response\"}.\n3. To append messages to the conversation log, emit: tool_call with name=\"convo.appendMessage\" and arguments={\"role\": \"user\"|\"assistant\", \"text\": \"...\", \"isPartial\": false}.\n4. To change app state, emit: tool_call with name=\"convo.setState\" and arguments={\"state\": \"thinking\"|\"speaking\"|\"idle\"}.\n5. NEVER request stt.start or stt.stop \u2014 those are user-driven.\n6. Keep spoken text concise and voice-friendly (short sentences, no markdown).\n7. Always follow this sequence for a response:\n   a. tool_call convo.setState {state: \"thinking\"}\n   b. tool_call convo.appendMessage {role: \"user\", text: <user's transcript>}\n   c. tool_call convo.appendMessage {role: \"assistant\", text: <your response text>}\n   d. tool_call convo.setState {state: \"speaking\"}\n   e. tool_call tts.speak {text: <your response text>}\n   f. tool_call convo.setState {state: \"idle\"}\n8. Use a friendly, conversational voice style. Be helpful and concise.\n9. If you are unsure, say so honestly. Do not make up information.";
/**
 * We define a single Bedrock tool "tool_call" that wraps all client-side tools.
 * The model emits tool_call requests with {name, arguments, call_id} to invoke
 * specific client tools. The backend forwards these to the iOS client.
 */
export declare const TOOL_CONFIG: ToolConfiguration;
export interface StreamTextDelta {
    type: 'text_delta';
    text: string;
}
export interface StreamToolUse {
    type: 'tool_use';
    toolUseId: string;
    name: string;
    input: {
        name: string;
        arguments: Record<string, unknown>;
        call_id: string;
    };
}
export interface StreamComplete {
    type: 'complete';
    stopReason: string;
}
export interface StreamError {
    type: 'error';
    message: string;
}
export type StreamChunk = StreamTextDelta | StreamToolUse | StreamComplete | StreamError;
/**
 * Call Bedrock ConverseStream and yield chunks as they arrive.
 * This is an async generator that yields StreamChunk objects.
 */
export declare function converseStream(conversation: BedrockMessage[], sessionId: string): AsyncGenerator<StreamChunk>;
//# sourceMappingURL=bedrock.d.ts.map
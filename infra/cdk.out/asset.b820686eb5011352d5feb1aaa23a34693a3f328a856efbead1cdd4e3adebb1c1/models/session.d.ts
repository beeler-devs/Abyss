/**
 * Session and conversation models for DynamoDB persistence.
 */
export interface BedrockMessage {
    role: 'user' | 'assistant';
    content: BedrockContentBlock[];
}
export type BedrockContentBlock = {
    text: string;
} | {
    toolUse: {
        toolUseId: string;
        name: string;
        input: unknown;
    };
} | {
    toolResult: {
        toolUseId: string;
        content: Array<{
            text: string;
        }>;
        status?: 'success' | 'error';
    };
};
export interface SessionRecord {
    sessionId: string;
    conversation: BedrockMessage[];
    createdAt: string;
    updatedAt: string;
}
export interface ConnectionRecord {
    connectionId: string;
    sessionId: string;
    connectedAt: string;
}
export interface PendingToolCall {
    sessionId: string;
    pendingCallId: string;
    pendingToolName: string;
    bedrockToolUseId: string;
    createdAt: string;
    ttl: number;
}
/** Maximum number of conversation turns to keep (bounded growth). */
export declare const MAX_CONVERSATION_TURNS = 50;
/** TTL for pending tool calls (seconds). */
export declare const PENDING_TOOL_CALL_TTL = 300;
//# sourceMappingURL=session.d.ts.map
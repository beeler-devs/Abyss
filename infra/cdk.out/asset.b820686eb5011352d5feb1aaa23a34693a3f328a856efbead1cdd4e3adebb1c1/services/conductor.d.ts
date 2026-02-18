/**
 * Cloud Conductor — orchestrates the Bedrock <-> client tool-call loop.
 *
 * Flow:
 * 1. Receive transcript.final from client
 * 2. Build conversation, call Bedrock ConverseStream
 * 3. Stream speech partials/finals to client
 * 4. When model emits tool_call -> forward as tool.call to client, save pending state
 * 5. When client returns tool.result -> feed back into Bedrock, continue
 * 6. Repeat until model finishes (end_turn)
 */
export declare function handleTranscriptFinal(connectionId: string, sessionId: string, text: string): Promise<void>;
export declare function handleToolResult(connectionId: string, sessionId: string, callId: string, result: string | null, error: string | null): Promise<void>;
//# sourceMappingURL=conductor.d.ts.map
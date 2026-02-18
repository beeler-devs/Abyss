"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.handleTranscriptFinal = handleTranscriptFinal;
exports.handleToolResult = handleToolResult;
const lib_dynamodb_1 = require("@aws-sdk/lib-dynamodb");
const events_1 = require("../models/events");
const session_1 = require("../models/session");
const dynamodb_1 = require("./dynamodb");
const bedrock_1 = require("./bedrock");
const websocket_1 = require("./websocket");
const logger_1 = require("../utils/logger");
// ─── Handle transcript.final from client ────────────────────────────────────
async function handleTranscriptFinal(connectionId, sessionId, text) {
    const ctx = { sessionId, connectionId };
    logger_1.logger.info('Handling transcript.final', ctx, { text });
    // 1. Ensure session exists and get conversation history
    const session = await (0, dynamodb_1.getOrCreateSession)(sessionId);
    // 2. Append user message to conversation
    const userMessage = {
        role: 'user',
        content: [{ text }],
    };
    const conversation = [...session.conversation, userMessage];
    // 3. Call Bedrock and process stream
    await processBedrockStream(connectionId, sessionId, conversation);
}
// ─── Handle tool.result from client ─────────────────────────────────────────
async function handleToolResult(connectionId, sessionId, callId, result, error) {
    const ctx = { sessionId, connectionId, callId };
    logger_1.logger.info('Handling tool.result', ctx, { hasResult: !!result, hasError: !!error });
    // 1. Get pending tool call
    const pending = await (0, dynamodb_1.getPendingToolCall)(sessionId);
    if (!pending) {
        logger_1.logger.warn('No pending tool call found for session', ctx);
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('no_pending_tool_call', `No pending tool call for session ${sessionId}`));
        return;
    }
    if (pending.pendingCallId !== callId) {
        logger_1.logger.warn('Tool result callId mismatch', ctx, {
            expected: pending.pendingCallId,
            received: callId,
        });
    }
    // 2. Clear pending state
    await (0, dynamodb_1.deletePendingToolCall)(sessionId);
    // 3. Get current session conversation
    const session = await (0, dynamodb_1.getOrCreateSession)(sessionId);
    const conversation = [...session.conversation];
    // 4. Add the tool result to conversation as a user message with toolResult content
    const toolResultContent = {
        toolResult: {
            toolUseId: pending.bedrockToolUseId,
            content: [{ text: result || error || '{}' }],
            status: error ? 'error' : 'success',
        },
    };
    const toolResultMessage = {
        role: 'user',
        content: [toolResultContent],
    };
    conversation.push(toolResultMessage);
    // 5. Continue the Bedrock conversation
    await processBedrockStream(connectionId, sessionId, conversation);
}
// ─── Process Bedrock stream and forward events ──────────────────────────────
async function processBedrockStream(connectionId, sessionId, conversation) {
    const ctx = { sessionId, connectionId };
    let speechBuffer = '';
    const assistantContentBlocks = [];
    try {
        for await (const chunk of (0, bedrock_1.converseStream)(conversation, sessionId)) {
            switch (chunk.type) {
                case 'text_delta': {
                    // Stream speech partial to client
                    speechBuffer += chunk.text;
                    await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeSpeechPartialEvent)(speechBuffer));
                    break;
                }
                case 'tool_use': {
                    // Finalize any accumulated speech text first
                    if (speechBuffer.length > 0) {
                        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeSpeechFinalEvent)(speechBuffer));
                        assistantContentBlocks.push({ text: speechBuffer });
                        speechBuffer = '';
                    }
                    // The model emitted a tool_call through the "tool_call" wrapper tool.
                    // Extract the inner tool name and arguments.
                    const innerName = chunk.input?.name;
                    const innerArgs = chunk.input?.arguments;
                    const innerCallId = chunk.input?.call_id || chunk.toolUseId;
                    if (!innerName) {
                        logger_1.logger.error('tool_call missing inner name', ctx, { toolUseId: chunk.toolUseId });
                        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('invalid_tool_call', 'Model emitted tool_call without a name'));
                        break;
                    }
                    // Record the tool_use block for the assistant message
                    assistantContentBlocks.push({
                        toolUse: {
                            toolUseId: chunk.toolUseId,
                            name: chunk.name, // "tool_call" (the wrapper)
                            input: chunk.input,
                        },
                    });
                    // Save pending state in DynamoDB
                    await (0, dynamodb_1.putPendingToolCall)(sessionId, innerCallId, innerName, chunk.toolUseId);
                    // Save conversation so far (assistant message with tool_use blocks)
                    const messagesWithAssistant = [
                        ...conversation,
                        { role: 'assistant', content: [...assistantContentBlocks] },
                    ];
                    await saveFullConversation(sessionId, messagesWithAssistant);
                    // Forward tool.call to the iOS client
                    const argsJson = typeof innerArgs === 'string'
                        ? innerArgs
                        : JSON.stringify(innerArgs || {});
                    const toolCallEvent = (0, events_1.makeToolCallEvent)(innerCallId, innerName, argsJson);
                    await (0, websocket_1.sendToConnection)(connectionId, toolCallEvent);
                    logger_1.logger.info('Tool call forwarded to client', ctx, {
                        callId: innerCallId,
                        toolName: innerName,
                    });
                    // STOP processing — wait for tool.result from client.
                    // A new Lambda invocation will resume when the client responds.
                    return;
                }
                case 'complete': {
                    // Finalize any remaining speech
                    if (speechBuffer.length > 0) {
                        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeSpeechFinalEvent)(speechBuffer));
                        assistantContentBlocks.push({ text: speechBuffer });
                        speechBuffer = '';
                    }
                    // Save the complete assistant response
                    if (assistantContentBlocks.length > 0) {
                        const fullConversation = [
                            ...conversation,
                            { role: 'assistant', content: assistantContentBlocks },
                        ];
                        await saveFullConversation(sessionId, fullConversation);
                    }
                    logger_1.logger.info('Bedrock stream complete', ctx, {
                        stopReason: chunk.stopReason,
                    });
                    break;
                }
                case 'error': {
                    logger_1.logger.error('Bedrock stream error', ctx, { message: chunk.message });
                    await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('bedrock_error', chunk.message));
                    break;
                }
            }
        }
    }
    catch (err) {
        const message = err.message || 'Unknown conductor error';
        logger_1.logger.error('Conductor error', ctx, { error: message });
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('conductor_error', message));
    }
}
// ─── Helper: save full conversation (bounded) ───────────────────────────────
async function saveFullConversation(sessionId, conversation) {
    let bounded = conversation;
    if (bounded.length > session_1.MAX_CONVERSATION_TURNS) {
        bounded = bounded.slice(bounded.length - session_1.MAX_CONVERSATION_TURNS);
    }
    await dynamodb_1.docClient.send(new lib_dynamodb_1.UpdateCommand({
        TableName: dynamodb_1.SESSIONS_TABLE,
        Key: { sessionId },
        UpdateExpression: 'SET conversation = :conv, updatedAt = :now',
        ExpressionAttributeValues: {
            ':conv': bounded,
            ':now': new Date().toISOString(),
        },
    }));
}
//# sourceMappingURL=conductor.js.map
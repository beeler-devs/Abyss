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

import { UpdateCommand } from '@aws-sdk/lib-dynamodb';
import {
  makeToolCallEvent,
  makeSpeechPartialEvent,
  makeSpeechFinalEvent,
  makeErrorEvent,
} from '../models/events';
import { BedrockMessage, BedrockContentBlock, MAX_CONVERSATION_TURNS } from '../models/session';
import {
  getOrCreateSession,
  putPendingToolCall,
  getPendingToolCall,
  deletePendingToolCall,
  docClient,
  SESSIONS_TABLE,
} from './dynamodb';
import { converseStream } from './bedrock';
import { sendToConnection } from './websocket';
import { logger } from '../utils/logger';

// ─── Handle transcript.final from client ────────────────────────────────────

export async function handleTranscriptFinal(
  connectionId: string,
  sessionId: string,
  text: string,
): Promise<void> {
  const ctx = { sessionId, connectionId };

  logger.info('Handling transcript.final', ctx, { text });

  // 1. Ensure session exists and get conversation history
  const session = await getOrCreateSession(sessionId);

  // 2. Append user message to conversation
  const userMessage: BedrockMessage = {
    role: 'user',
    content: [{ text }],
  };

  const conversation = [...session.conversation, userMessage];

  // 3. Call Bedrock and process stream
  await processBedrockStream(connectionId, sessionId, conversation);
}

// ─── Handle tool.result from client ─────────────────────────────────────────

export async function handleToolResult(
  connectionId: string,
  sessionId: string,
  callId: string,
  result: string | null,
  error: string | null,
): Promise<void> {
  const ctx = { sessionId, connectionId, callId };

  logger.info('Handling tool.result', ctx, { hasResult: !!result, hasError: !!error });

  // 1. Get pending tool call
  const pending = await getPendingToolCall(sessionId);
  if (!pending) {
    logger.warn('No pending tool call found for session', ctx);
    await sendToConnection(connectionId, makeErrorEvent(
      'no_pending_tool_call',
      `No pending tool call for session ${sessionId}`,
    ));
    return;
  }

  if (pending.pendingCallId !== callId) {
    logger.warn('Tool result callId mismatch', ctx, {
      expected: pending.pendingCallId,
      received: callId,
    });
  }

  // 2. Clear pending state
  await deletePendingToolCall(sessionId);

  // 3. Get current session conversation
  const session = await getOrCreateSession(sessionId);
  const conversation = [...session.conversation];

  // 4. Add the tool result to conversation as a user message with toolResult content
  const toolResultContent: BedrockContentBlock = {
    toolResult: {
      toolUseId: pending.bedrockToolUseId,
      content: [{ text: result || error || '{}' }],
      status: error ? 'error' : 'success',
    },
  };

  const toolResultMessage: BedrockMessage = {
    role: 'user',
    content: [toolResultContent],
  };

  conversation.push(toolResultMessage);

  // 5. Continue the Bedrock conversation
  await processBedrockStream(connectionId, sessionId, conversation);
}

// ─── Process Bedrock stream and forward events ──────────────────────────────

async function processBedrockStream(
  connectionId: string,
  sessionId: string,
  conversation: BedrockMessage[],
): Promise<void> {
  const ctx = { sessionId, connectionId };

  let speechBuffer = '';
  const assistantContentBlocks: BedrockContentBlock[] = [];

  try {
    for await (const chunk of converseStream(conversation, sessionId)) {
      switch (chunk.type) {
        case 'text_delta': {
          // Stream speech partial to client
          speechBuffer += chunk.text;
          await sendToConnection(connectionId, makeSpeechPartialEvent(speechBuffer));
          break;
        }

        case 'tool_use': {
          // Finalize any accumulated speech text first
          if (speechBuffer.length > 0) {
            await sendToConnection(connectionId, makeSpeechFinalEvent(speechBuffer));
            assistantContentBlocks.push({ text: speechBuffer });
            speechBuffer = '';
          }

          // The model emitted a tool_call through the "tool_call" wrapper tool.
          // Extract the inner tool name and arguments.
          const innerName = chunk.input?.name;
          const innerArgs = chunk.input?.arguments;
          const innerCallId = chunk.input?.call_id || chunk.toolUseId;

          if (!innerName) {
            logger.error('tool_call missing inner name', ctx, { toolUseId: chunk.toolUseId });
            await sendToConnection(connectionId, makeErrorEvent(
              'invalid_tool_call',
              'Model emitted tool_call without a name',
            ));
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
          await putPendingToolCall(
            sessionId,
            innerCallId,
            innerName,
            chunk.toolUseId,
          );

          // Save conversation so far (assistant message with tool_use blocks)
          const messagesWithAssistant: BedrockMessage[] = [
            ...conversation,
            { role: 'assistant', content: [...assistantContentBlocks] },
          ];
          await saveFullConversation(sessionId, messagesWithAssistant);

          // Forward tool.call to the iOS client
          const argsJson = typeof innerArgs === 'string'
            ? innerArgs
            : JSON.stringify(innerArgs || {});

          const toolCallEvent = makeToolCallEvent(innerCallId, innerName, argsJson);
          await sendToConnection(connectionId, toolCallEvent);

          logger.info('Tool call forwarded to client', ctx, {
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
            await sendToConnection(connectionId, makeSpeechFinalEvent(speechBuffer));
            assistantContentBlocks.push({ text: speechBuffer });
            speechBuffer = '';
          }

          // Save the complete assistant response
          if (assistantContentBlocks.length > 0) {
            const fullConversation: BedrockMessage[] = [
              ...conversation,
              { role: 'assistant', content: assistantContentBlocks },
            ];
            await saveFullConversation(sessionId, fullConversation);
          }

          logger.info('Bedrock stream complete', ctx, {
            stopReason: chunk.stopReason,
          });
          break;
        }

        case 'error': {
          logger.error('Bedrock stream error', ctx, { message: chunk.message });
          await sendToConnection(connectionId, makeErrorEvent('bedrock_error', chunk.message));
          break;
        }
      }
    }
  } catch (err) {
    const message = (err as Error).message || 'Unknown conductor error';
    logger.error('Conductor error', ctx, { error: message });
    await sendToConnection(connectionId, makeErrorEvent('conductor_error', message));
  }
}

// ─── Helper: save full conversation (bounded) ───────────────────────────────

async function saveFullConversation(
  sessionId: string,
  conversation: BedrockMessage[],
): Promise<void> {
  let bounded = conversation;
  if (bounded.length > MAX_CONVERSATION_TURNS) {
    bounded = bounded.slice(bounded.length - MAX_CONVERSATION_TURNS);
  }

  await docClient.send(new UpdateCommand({
    TableName: SESSIONS_TABLE,
    Key: { sessionId },
    UpdateExpression: 'SET conversation = :conv, updatedAt = :now',
    ExpressionAttributeValues: {
      ':conv': bounded,
      ':now': new Date().toISOString(),
    },
  }));
}

/**
 * sendMessage handler — processes inbound WebSocket messages from the iOS client.
 *
 * Dispatches based on event kind:
 * - sessionStart: initialize session
 * - userAudioTranscriptFinal: send to Bedrock via conductor
 * - toolResult: feed tool result back to conductor
 */

import { APIGatewayProxyResult } from 'aws-lambda';
import {
  validateWireEvent,
  isSessionStart,
  isTranscriptFinal,
  isToolResult,
  makeErrorEvent,
} from '../models/events';
import { getConnection, getOrCreateSession } from '../services/dynamodb';
import { handleTranscriptFinal, handleToolResult } from '../services/conductor';
import { initApiGwClient, sendToConnection } from '../services/websocket';
import { initBedrockClient } from '../services/bedrock';
import { logger } from '../utils/logger';

// ─── WebSocket message event type ───────────────────────────────────────────

interface WebSocketMessageEvent {
  requestContext: {
    connectionId: string;
    requestId: string;
    domainName: string;
    stage: string;
  };
  body?: string;
}

// ─── Initialize clients once (warm Lambda) ──────────────────────────────────

let initialized = false;

function ensureInitialized(domainName: string, stage: string): void {
  if (initialized) return;

  const endpoint = `https://${domainName}/${stage}`;
  initApiGwClient(endpoint);
  initBedrockClient();
  initialized = true;
}

// ─── Handler ────────────────────────────────────────────────────────────────

export const handler = async (event: WebSocketMessageEvent): Promise<APIGatewayProxyResult> => {
  const connectionId = event.requestContext.connectionId;
  const requestId = event.requestContext.requestId;
  const domainName = event.requestContext.domainName;
  const stage = event.requestContext.stage;

  ensureInitialized(domainName, stage);

  const ctx = { connectionId, requestId };

  logger.info('WebSocket message received', ctx);

  // Parse the message body
  let body: unknown;
  try {
    body = JSON.parse(event.body || '{}');
  } catch {
    logger.warn('Invalid JSON in message body', ctx);
    await sendToConnection(connectionId, makeErrorEvent('invalid_json', 'Message body is not valid JSON'));
    return { statusCode: 400, body: 'Invalid JSON' };
  }

  // Validate the event shape
  const validation = validateWireEvent(body);
  if (!validation.valid) {
    logger.warn('Invalid event shape', ctx, { error: validation.error });
    await sendToConnection(connectionId, makeErrorEvent('invalid_event', validation.error));
    return { statusCode: 400, body: validation.error };
  }

  const wireEvent = validation.event;
  const kind = wireEvent.kind;

  // Look up session for this connection
  const connection = await getConnection(connectionId);
  if (!connection) {
    logger.error('No connection record found', ctx);
    await sendToConnection(connectionId, makeErrorEvent('no_session', 'Connection not found. Reconnect with sessionId.'));
    return { statusCode: 400, body: 'No connection record' };
  }

  const sessionId = connection.sessionId;
  const sessionCtx = { ...ctx, sessionId };

  logger.info('Processing event', sessionCtx, {
    eventKind: Object.keys(kind)[0],
    eventId: wireEvent.id,
  });

  try {
    // ─── Dispatch by event kind ───────────────────────────────────────

    if (isSessionStart(kind)) {
      // Initialize session in DynamoDB
      await getOrCreateSession(kind.sessionStart.sessionId);
      logger.info('Session initialized', sessionCtx);
      return { statusCode: 200, body: 'OK' };
    }

    if (isTranscriptFinal(kind)) {
      const text = kind.userAudioTranscriptFinal.text;
      if (!text || text.trim().length === 0) {
        logger.warn('Empty transcript received', sessionCtx);
        await sendToConnection(connectionId, makeErrorEvent('empty_transcript', 'Transcript text is empty'));
        return { statusCode: 400, body: 'Empty transcript' };
      }

      await handleTranscriptFinal(connectionId, sessionId, text);
      return { statusCode: 200, body: 'OK' };
    }

    if (isToolResult(kind)) {
      const { callId, result, error } = kind.toolResult;
      await handleToolResult(connectionId, sessionId, callId, result, error);
      return { statusCode: 200, body: 'OK' };
    }

    // Unknown event kind — log and ignore
    logger.warn('Unhandled event kind', sessionCtx, {
      kind: Object.keys(kind)[0],
    });

    return { statusCode: 200, body: 'OK' };

  } catch (err) {
    const message = (err as Error).message || 'Unknown error';
    logger.error('Handler error', sessionCtx, { error: message });
    await sendToConnection(connectionId, makeErrorEvent('handler_error', message));
    return { statusCode: 500, body: 'Internal server error' };
  }
};

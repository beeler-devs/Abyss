/**
 * $connect handler — WebSocket connection established.
 *
 * Stores connectionId -> sessionId mapping in DynamoDB.
 * The sessionId is passed as a query string parameter.
 */

import { APIGatewayProxyResult } from 'aws-lambda';
import { putConnection } from '../services/dynamodb';
import { logger } from '../utils/logger';

// WebSocket $connect events include queryStringParameters (like HTTP events)
// but the V2 WebSocket type doesn't declare them. Use a broader type.
interface WebSocketConnectEvent {
  requestContext: {
    connectionId: string;
    requestId: string;
  };
  queryStringParameters?: Record<string, string | undefined>;
}

export const handler = async (event: WebSocketConnectEvent): Promise<APIGatewayProxyResult> => {
  const connectionId = event.requestContext.connectionId;
  const sessionId = event.queryStringParameters?.sessionId;
  const requestId = event.requestContext.requestId;

  const ctx = { connectionId, sessionId, requestId };

  logger.info('WebSocket $connect', ctx);

  if (!sessionId || sessionId.length === 0) {
    logger.warn('Missing sessionId query parameter', ctx);
    return {
      statusCode: 400,
      body: 'Missing required query parameter: sessionId',
    };
  }

  // Validate sessionId format (UUID-like)
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(sessionId)) {
    logger.warn('Invalid sessionId format', ctx);
    return {
      statusCode: 400,
      body: 'sessionId must be a valid UUID',
    };
  }

  try {
    await putConnection(connectionId, sessionId);

    logger.info('Connection established', ctx);
    return { statusCode: 200, body: 'Connected' };
  } catch (err) {
    logger.error('Failed to save connection', ctx, {
      error: (err as Error).message,
    });
    return { statusCode: 500, body: 'Internal server error' };
  }
};

/**
 * $disconnect handler — WebSocket connection closed.
 *
 * Cleans up the connection mapping in DynamoDB.
 */

import { APIGatewayProxyResult } from 'aws-lambda';
import { deleteConnection } from '../services/dynamodb';
import { logger } from '../utils/logger';

interface WebSocketEvent {
  requestContext: {
    connectionId: string;
    requestId: string;
  };
}

export const handler = async (event: WebSocketEvent): Promise<APIGatewayProxyResult> => {
  const connectionId = event.requestContext.connectionId;
  const requestId = event.requestContext.requestId;

  const ctx = { connectionId, requestId };

  logger.info('WebSocket $disconnect', ctx);

  try {
    await deleteConnection(connectionId);
    logger.info('Connection cleaned up', ctx);
  } catch (err) {
    logger.error('Failed to clean up connection', ctx, {
      error: (err as Error).message,
    });
  }

  return { statusCode: 200, body: 'Disconnected' };
};

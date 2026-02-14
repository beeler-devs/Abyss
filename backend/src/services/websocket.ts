/**
 * WebSocket push service using API Gateway Management API.
 * Sends WireEvents back to connected iOS clients.
 */

import {
  ApiGatewayManagementApiClient,
  PostToConnectionCommand,
  GoneException,
} from '@aws-sdk/client-apigatewaymanagementapi';
import { WireEvent } from '../models/events';
import { logger } from '../utils/logger';

let apiGwClient: ApiGatewayManagementApiClient | null = null;

/**
 * Initialize the API Gateway Management API client.
 * Must be called with the WebSocket API endpoint URL.
 */
export function initApiGwClient(endpoint: string): void {
  apiGwClient = new ApiGatewayManagementApiClient({
    endpoint,
  });
}

/**
 * Get the current client (for testing injection).
 */
export function getApiGwClient(): ApiGatewayManagementApiClient {
  if (!apiGwClient) {
    throw new Error('API Gateway Management client not initialized. Call initApiGwClient() first.');
  }
  return apiGwClient;
}

/**
 * Set a custom client (for testing).
 */
export function setApiGwClient(client: ApiGatewayManagementApiClient): void {
  apiGwClient = client;
}

/**
 * Send a WireEvent to a specific WebSocket connection.
 * Returns false if the connection is gone (stale).
 */
export async function sendToConnection(connectionId: string, event: WireEvent): Promise<boolean> {
  const client = getApiGwClient();
  const payload = JSON.stringify(event);

  try {
    await client.send(new PostToConnectionCommand({
      ConnectionId: connectionId,
      Data: Buffer.from(payload),
    }));

    logger.debug('Event sent to connection', { connectionId }, {
      eventKind: Object.keys(event.kind)[0],
    });

    return true;
  } catch (err) {
    if (err instanceof GoneException) {
      logger.warn('Connection gone (stale)', { connectionId });
      return false;
    }
    logger.error('Failed to send to connection', { connectionId }, {
      error: (err as Error).message,
    });
    throw err;
  }
}

/**
 * Send multiple events to a connection in order.
 */
export async function sendEventsToConnection(connectionId: string, events: WireEvent[]): Promise<void> {
  for (const event of events) {
    const ok = await sendToConnection(connectionId, event);
    if (!ok) {
      logger.warn('Stopping event send — connection gone', { connectionId });
      break;
    }
  }
}

/**
 * WebSocket push service using API Gateway Management API.
 * Sends WireEvents back to connected iOS clients.
 */
import { ApiGatewayManagementApiClient } from '@aws-sdk/client-apigatewaymanagementapi';
import { WireEvent } from '../models/events';
/**
 * Initialize the API Gateway Management API client.
 * Must be called with the WebSocket API endpoint URL.
 */
export declare function initApiGwClient(endpoint: string): void;
/**
 * Get the current client (for testing injection).
 */
export declare function getApiGwClient(): ApiGatewayManagementApiClient;
/**
 * Set a custom client (for testing).
 */
export declare function setApiGwClient(client: ApiGatewayManagementApiClient): void;
/**
 * Send a WireEvent to a specific WebSocket connection.
 * Returns false if the connection is gone (stale).
 */
export declare function sendToConnection(connectionId: string, event: WireEvent): Promise<boolean>;
/**
 * Send multiple events to a connection in order.
 */
export declare function sendEventsToConnection(connectionId: string, events: WireEvent[]): Promise<void>;
//# sourceMappingURL=websocket.d.ts.map
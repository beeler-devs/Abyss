/**
 * $disconnect handler — WebSocket connection closed.
 *
 * Cleans up the connection mapping in DynamoDB.
 */
import { APIGatewayProxyResult } from 'aws-lambda';
interface WebSocketEvent {
    requestContext: {
        connectionId: string;
        requestId: string;
    };
}
export declare const handler: (event: WebSocketEvent) => Promise<APIGatewayProxyResult>;
export {};
//# sourceMappingURL=disconnect.d.ts.map
/**
 * $connect handler — WebSocket connection established.
 *
 * Stores connectionId -> sessionId mapping in DynamoDB.
 * The sessionId is passed as a query string parameter.
 */
import { APIGatewayProxyResult } from 'aws-lambda';
interface WebSocketConnectEvent {
    requestContext: {
        connectionId: string;
        requestId: string;
    };
    queryStringParameters?: Record<string, string | undefined>;
}
export declare const handler: (event: WebSocketConnectEvent) => Promise<APIGatewayProxyResult>;
export {};
//# sourceMappingURL=connect.d.ts.map
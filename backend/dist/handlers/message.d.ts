/**
 * sendMessage handler — processes inbound WebSocket messages from the iOS client.
 *
 * Dispatches based on event kind:
 * - sessionStart: initialize session
 * - userAudioTranscriptFinal: send to Bedrock via conductor
 * - toolResult: feed tool result back to conductor
 */
import { APIGatewayProxyResult } from 'aws-lambda';
interface WebSocketMessageEvent {
    requestContext: {
        connectionId: string;
        requestId: string;
        domainName: string;
        stage: string;
    };
    body?: string;
}
export declare const handler: (event: WebSocketMessageEvent) => Promise<APIGatewayProxyResult>;
export {};
//# sourceMappingURL=message.d.ts.map
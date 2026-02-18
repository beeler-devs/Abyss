/**
 * DynamoDB operations for Connections, Sessions, and Pending tool calls.
 */
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { ConnectionRecord, SessionRecord, PendingToolCall, BedrockMessage } from '../models/session';
declare const docClient: DynamoDBDocumentClient;
declare const CONNECTIONS_TABLE: string;
declare const SESSIONS_TABLE: string;
declare const PENDING_TABLE: string;
export declare function putConnection(connectionId: string, sessionId: string): Promise<void>;
export declare function getConnection(connectionId: string): Promise<ConnectionRecord | null>;
export declare function deleteConnection(connectionId: string): Promise<void>;
export declare function getOrCreateSession(sessionId: string): Promise<SessionRecord>;
export declare function appendToConversation(sessionId: string, messages: BedrockMessage[]): Promise<void>;
export declare function getSession(sessionId: string): Promise<SessionRecord | null>;
export declare function putPendingToolCall(sessionId: string, pendingCallId: string, pendingToolName: string, bedrockToolUseId: string): Promise<void>;
export declare function getPendingToolCall(sessionId: string): Promise<PendingToolCall | null>;
export declare function deletePendingToolCall(sessionId: string): Promise<void>;
export { docClient, CONNECTIONS_TABLE, SESSIONS_TABLE, PENDING_TABLE };
//# sourceMappingURL=dynamodb.d.ts.map
/**
 * DynamoDB operations for Connections, Sessions, and Pending tool calls.
 */

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  DeleteCommand,
  UpdateCommand,
  QueryCommand,
} from '@aws-sdk/lib-dynamodb';
import {
  ConnectionRecord,
  SessionRecord,
  PendingToolCall,
  BedrockMessage,
  MAX_CONVERSATION_TURNS,
  PENDING_TOOL_CALL_TTL,
} from '../models/session';
import { logger } from '../utils/logger';

// ─── Client singleton ───────────────────────────────────────────────────────

const ddbClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(ddbClient, {
  marshallOptions: { removeUndefinedValues: true },
});

// ─── Table names from env ───────────────────────────────────────────────────

const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE || 'VoiceIDE-Connections';
const SESSIONS_TABLE = process.env.SESSIONS_TABLE || 'VoiceIDE-Sessions';
const PENDING_TABLE = process.env.PENDING_TABLE || 'VoiceIDE-Pending';

// ─── Connections ────────────────────────────────────────────────────────────

export async function putConnection(connectionId: string, sessionId: string): Promise<void> {
  const record: ConnectionRecord = {
    connectionId,
    sessionId,
    connectedAt: new Date().toISOString(),
  };
  await docClient.send(new PutCommand({
    TableName: CONNECTIONS_TABLE,
    Item: record,
  }));
  logger.info('Connection saved', { connectionId, sessionId });
}

export async function getConnection(connectionId: string): Promise<ConnectionRecord | null> {
  const result = await docClient.send(new GetCommand({
    TableName: CONNECTIONS_TABLE,
    Key: { connectionId },
  }));
  return (result.Item as ConnectionRecord) || null;
}

export async function deleteConnection(connectionId: string): Promise<void> {
  await docClient.send(new DeleteCommand({
    TableName: CONNECTIONS_TABLE,
    Key: { connectionId },
  }));
  logger.info('Connection deleted', { connectionId });
}

// ─── Sessions ───────────────────────────────────────────────────────────────

export async function getOrCreateSession(sessionId: string): Promise<SessionRecord> {
  const result = await docClient.send(new GetCommand({
    TableName: SESSIONS_TABLE,
    Key: { sessionId },
  }));

  if (result.Item) {
    return result.Item as SessionRecord;
  }

  const now = new Date().toISOString();
  const session: SessionRecord = {
    sessionId,
    conversation: [],
    createdAt: now,
    updatedAt: now,
  };

  await docClient.send(new PutCommand({
    TableName: SESSIONS_TABLE,
    Item: session,
  }));

  logger.info('Session created', { sessionId });
  return session;
}

export async function appendToConversation(
  sessionId: string,
  messages: BedrockMessage[],
): Promise<void> {
  // Get current session to enforce bounds
  const session = await getOrCreateSession(sessionId);
  let conversation = [...session.conversation, ...messages];

  // Bound conversation growth: keep last MAX_CONVERSATION_TURNS messages
  if (conversation.length > MAX_CONVERSATION_TURNS) {
    conversation = conversation.slice(conversation.length - MAX_CONVERSATION_TURNS);
  }

  await docClient.send(new UpdateCommand({
    TableName: SESSIONS_TABLE,
    Key: { sessionId },
    UpdateExpression: 'SET conversation = :conv, updatedAt = :now',
    ExpressionAttributeValues: {
      ':conv': conversation,
      ':now': new Date().toISOString(),
    },
  }));

  logger.debug('Conversation updated', { sessionId }, {
    messageCount: conversation.length,
  });
}

export async function getSession(sessionId: string): Promise<SessionRecord | null> {
  const result = await docClient.send(new GetCommand({
    TableName: SESSIONS_TABLE,
    Key: { sessionId },
  }));
  return (result.Item as SessionRecord) || null;
}

// ─── Pending tool calls ─────────────────────────────────────────────────────

export async function putPendingToolCall(
  sessionId: string,
  pendingCallId: string,
  pendingToolName: string,
  bedrockToolUseId: string,
): Promise<void> {
  const record: PendingToolCall = {
    sessionId,
    pendingCallId,
    pendingToolName,
    bedrockToolUseId,
    createdAt: new Date().toISOString(),
    ttl: Math.floor(Date.now() / 1000) + PENDING_TOOL_CALL_TTL,
  };

  await docClient.send(new PutCommand({
    TableName: PENDING_TABLE,
    Item: record,
  }));

  logger.debug('Pending tool call saved', { sessionId, callId: pendingCallId });
}

export async function getPendingToolCall(sessionId: string): Promise<PendingToolCall | null> {
  const result = await docClient.send(new GetCommand({
    TableName: PENDING_TABLE,
    Key: { sessionId },
  }));
  return (result.Item as PendingToolCall) || null;
}

export async function deletePendingToolCall(sessionId: string): Promise<void> {
  await docClient.send(new DeleteCommand({
    TableName: PENDING_TABLE,
    Key: { sessionId },
  }));
  logger.debug('Pending tool call cleared', { sessionId });
}

// ─── Exported for testing ───────────────────────────────────────────────────

export { docClient, CONNECTIONS_TABLE, SESSIONS_TABLE, PENDING_TABLE };

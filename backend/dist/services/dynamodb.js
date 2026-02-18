"use strict";
/**
 * DynamoDB operations for Connections, Sessions, and Pending tool calls.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.PENDING_TABLE = exports.SESSIONS_TABLE = exports.CONNECTIONS_TABLE = exports.docClient = void 0;
exports.putConnection = putConnection;
exports.getConnection = getConnection;
exports.deleteConnection = deleteConnection;
exports.getOrCreateSession = getOrCreateSession;
exports.appendToConversation = appendToConversation;
exports.getSession = getSession;
exports.putPendingToolCall = putPendingToolCall;
exports.getPendingToolCall = getPendingToolCall;
exports.deletePendingToolCall = deletePendingToolCall;
const client_dynamodb_1 = require("@aws-sdk/client-dynamodb");
const lib_dynamodb_1 = require("@aws-sdk/lib-dynamodb");
const session_1 = require("../models/session");
const logger_1 = require("../utils/logger");
// ─── Client singleton ───────────────────────────────────────────────────────
const ddbClient = new client_dynamodb_1.DynamoDBClient({});
const docClient = lib_dynamodb_1.DynamoDBDocumentClient.from(ddbClient, {
    marshallOptions: { removeUndefinedValues: true },
});
exports.docClient = docClient;
// ─── Table names from env ───────────────────────────────────────────────────
const CONNECTIONS_TABLE = process.env.CONNECTIONS_TABLE || 'VoiceIDE-Connections';
exports.CONNECTIONS_TABLE = CONNECTIONS_TABLE;
const SESSIONS_TABLE = process.env.SESSIONS_TABLE || 'VoiceIDE-Sessions';
exports.SESSIONS_TABLE = SESSIONS_TABLE;
const PENDING_TABLE = process.env.PENDING_TABLE || 'VoiceIDE-Pending';
exports.PENDING_TABLE = PENDING_TABLE;
// ─── Connections ────────────────────────────────────────────────────────────
async function putConnection(connectionId, sessionId) {
    const record = {
        connectionId,
        sessionId,
        connectedAt: new Date().toISOString(),
    };
    await docClient.send(new lib_dynamodb_1.PutCommand({
        TableName: CONNECTIONS_TABLE,
        Item: record,
    }));
    logger_1.logger.info('Connection saved', { connectionId, sessionId });
}
async function getConnection(connectionId) {
    const result = await docClient.send(new lib_dynamodb_1.GetCommand({
        TableName: CONNECTIONS_TABLE,
        Key: { connectionId },
    }));
    return result.Item || null;
}
async function deleteConnection(connectionId) {
    await docClient.send(new lib_dynamodb_1.DeleteCommand({
        TableName: CONNECTIONS_TABLE,
        Key: { connectionId },
    }));
    logger_1.logger.info('Connection deleted', { connectionId });
}
// ─── Sessions ───────────────────────────────────────────────────────────────
async function getOrCreateSession(sessionId) {
    const result = await docClient.send(new lib_dynamodb_1.GetCommand({
        TableName: SESSIONS_TABLE,
        Key: { sessionId },
    }));
    if (result.Item) {
        return result.Item;
    }
    const now = new Date().toISOString();
    const session = {
        sessionId,
        conversation: [],
        createdAt: now,
        updatedAt: now,
    };
    await docClient.send(new lib_dynamodb_1.PutCommand({
        TableName: SESSIONS_TABLE,
        Item: session,
    }));
    logger_1.logger.info('Session created', { sessionId });
    return session;
}
async function appendToConversation(sessionId, messages) {
    // Get current session to enforce bounds
    const session = await getOrCreateSession(sessionId);
    let conversation = [...session.conversation, ...messages];
    // Bound conversation growth: keep last MAX_CONVERSATION_TURNS messages
    if (conversation.length > session_1.MAX_CONVERSATION_TURNS) {
        conversation = conversation.slice(conversation.length - session_1.MAX_CONVERSATION_TURNS);
    }
    await docClient.send(new lib_dynamodb_1.UpdateCommand({
        TableName: SESSIONS_TABLE,
        Key: { sessionId },
        UpdateExpression: 'SET conversation = :conv, updatedAt = :now',
        ExpressionAttributeValues: {
            ':conv': conversation,
            ':now': new Date().toISOString(),
        },
    }));
    logger_1.logger.debug('Conversation updated', { sessionId }, {
        messageCount: conversation.length,
    });
}
async function getSession(sessionId) {
    const result = await docClient.send(new lib_dynamodb_1.GetCommand({
        TableName: SESSIONS_TABLE,
        Key: { sessionId },
    }));
    return result.Item || null;
}
// ─── Pending tool calls ─────────────────────────────────────────────────────
async function putPendingToolCall(sessionId, pendingCallId, pendingToolName, bedrockToolUseId) {
    const record = {
        sessionId,
        pendingCallId,
        pendingToolName,
        bedrockToolUseId,
        createdAt: new Date().toISOString(),
        ttl: Math.floor(Date.now() / 1000) + session_1.PENDING_TOOL_CALL_TTL,
    };
    await docClient.send(new lib_dynamodb_1.PutCommand({
        TableName: PENDING_TABLE,
        Item: record,
    }));
    logger_1.logger.debug('Pending tool call saved', { sessionId, callId: pendingCallId });
}
async function getPendingToolCall(sessionId) {
    const result = await docClient.send(new lib_dynamodb_1.GetCommand({
        TableName: PENDING_TABLE,
        Key: { sessionId },
    }));
    return result.Item || null;
}
async function deletePendingToolCall(sessionId) {
    await docClient.send(new lib_dynamodb_1.DeleteCommand({
        TableName: PENDING_TABLE,
        Key: { sessionId },
    }));
    logger_1.logger.debug('Pending tool call cleared', { sessionId });
}
//# sourceMappingURL=dynamodb.js.map
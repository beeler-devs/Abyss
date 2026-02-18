"use strict";
/**
 * sendMessage handler — processes inbound WebSocket messages from the iOS client.
 *
 * Dispatches based on event kind:
 * - sessionStart: initialize session
 * - userAudioTranscriptFinal: send to Bedrock via conductor
 * - toolResult: feed tool result back to conductor
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.handler = void 0;
const events_1 = require("../models/events");
const dynamodb_1 = require("../services/dynamodb");
const conductor_1 = require("../services/conductor");
const websocket_1 = require("../services/websocket");
const bedrock_1 = require("../services/bedrock");
const logger_1 = require("../utils/logger");
// ─── Initialize clients once (warm Lambda) ──────────────────────────────────
let initialized = false;
function ensureInitialized(domainName, stage) {
    if (initialized)
        return;
    const endpoint = `https://${domainName}/${stage}`;
    (0, websocket_1.initApiGwClient)(endpoint);
    (0, bedrock_1.initBedrockClient)();
    initialized = true;
}
// ─── Handler ────────────────────────────────────────────────────────────────
const handler = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const requestId = event.requestContext.requestId;
    const domainName = event.requestContext.domainName;
    const stage = event.requestContext.stage;
    ensureInitialized(domainName, stage);
    const ctx = { connectionId, requestId };
    logger_1.logger.info('WebSocket message received', ctx);
    // Parse the message body
    let body;
    try {
        body = JSON.parse(event.body || '{}');
    }
    catch {
        logger_1.logger.warn('Invalid JSON in message body', ctx);
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('invalid_json', 'Message body is not valid JSON'));
        return { statusCode: 400, body: 'Invalid JSON' };
    }
    // Validate the event shape
    const validation = (0, events_1.validateWireEvent)(body);
    if (!validation.valid) {
        logger_1.logger.warn('Invalid event shape', ctx, { error: validation.error });
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('invalid_event', validation.error));
        return { statusCode: 400, body: validation.error };
    }
    const wireEvent = validation.event;
    const kind = wireEvent.kind;
    // Look up session for this connection
    const connection = await (0, dynamodb_1.getConnection)(connectionId);
    if (!connection) {
        logger_1.logger.error('No connection record found', ctx);
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('no_session', 'Connection not found. Reconnect with sessionId.'));
        return { statusCode: 400, body: 'No connection record' };
    }
    const sessionId = connection.sessionId;
    const sessionCtx = { ...ctx, sessionId };
    logger_1.logger.info('Processing event', sessionCtx, {
        eventKind: Object.keys(kind)[0],
        eventId: wireEvent.id,
    });
    try {
        // ─── Dispatch by event kind ───────────────────────────────────────
        if ((0, events_1.isSessionStart)(kind)) {
            // Initialize session in DynamoDB
            await (0, dynamodb_1.getOrCreateSession)(kind.sessionStart.sessionId);
            logger_1.logger.info('Session initialized', sessionCtx);
            return { statusCode: 200, body: 'OK' };
        }
        if ((0, events_1.isTranscriptFinal)(kind)) {
            const text = kind.userAudioTranscriptFinal.text;
            if (!text || text.trim().length === 0) {
                logger_1.logger.warn('Empty transcript received', sessionCtx);
                await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('empty_transcript', 'Transcript text is empty'));
                return { statusCode: 400, body: 'Empty transcript' };
            }
            await (0, conductor_1.handleTranscriptFinal)(connectionId, sessionId, text);
            return { statusCode: 200, body: 'OK' };
        }
        if ((0, events_1.isToolResult)(kind)) {
            const { callId, result, error } = kind.toolResult;
            await (0, conductor_1.handleToolResult)(connectionId, sessionId, callId, result, error);
            return { statusCode: 200, body: 'OK' };
        }
        // Unknown event kind — log and ignore
        logger_1.logger.warn('Unhandled event kind', sessionCtx, {
            kind: Object.keys(kind)[0],
        });
        return { statusCode: 200, body: 'OK' };
    }
    catch (err) {
        const message = err.message || 'Unknown error';
        logger_1.logger.error('Handler error', sessionCtx, { error: message });
        await (0, websocket_1.sendToConnection)(connectionId, (0, events_1.makeErrorEvent)('handler_error', message));
        return { statusCode: 500, body: 'Internal server error' };
    }
};
exports.handler = handler;
//# sourceMappingURL=message.js.map
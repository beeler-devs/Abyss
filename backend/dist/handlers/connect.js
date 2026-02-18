"use strict";
/**
 * $connect handler — WebSocket connection established.
 *
 * Stores connectionId -> sessionId mapping in DynamoDB.
 * The sessionId is passed as a query string parameter.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.handler = void 0;
const dynamodb_1 = require("../services/dynamodb");
const logger_1 = require("../utils/logger");
const handler = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const sessionId = event.queryStringParameters?.sessionId;
    const requestId = event.requestContext.requestId;
    const ctx = { connectionId, sessionId, requestId };
    logger_1.logger.info('WebSocket $connect', ctx);
    if (!sessionId || sessionId.length === 0) {
        logger_1.logger.warn('Missing sessionId query parameter', ctx);
        return {
            statusCode: 400,
            body: 'Missing required query parameter: sessionId',
        };
    }
    // Validate sessionId format (UUID-like)
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidRegex.test(sessionId)) {
        logger_1.logger.warn('Invalid sessionId format', ctx);
        return {
            statusCode: 400,
            body: 'sessionId must be a valid UUID',
        };
    }
    try {
        await (0, dynamodb_1.putConnection)(connectionId, sessionId);
        logger_1.logger.info('Connection established', ctx);
        return { statusCode: 200, body: 'Connected' };
    }
    catch (err) {
        logger_1.logger.error('Failed to save connection', ctx, {
            error: err.message,
        });
        return { statusCode: 500, body: 'Internal server error' };
    }
};
exports.handler = handler;
//# sourceMappingURL=connect.js.map
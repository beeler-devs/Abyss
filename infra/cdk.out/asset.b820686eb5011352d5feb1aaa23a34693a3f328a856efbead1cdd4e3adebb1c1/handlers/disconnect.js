"use strict";
/**
 * $disconnect handler — WebSocket connection closed.
 *
 * Cleans up the connection mapping in DynamoDB.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.handler = void 0;
const dynamodb_1 = require("../services/dynamodb");
const logger_1 = require("../utils/logger");
const handler = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const requestId = event.requestContext.requestId;
    const ctx = { connectionId, requestId };
    logger_1.logger.info('WebSocket $disconnect', ctx);
    try {
        await (0, dynamodb_1.deleteConnection)(connectionId);
        logger_1.logger.info('Connection cleaned up', ctx);
    }
    catch (err) {
        logger_1.logger.error('Failed to clean up connection', ctx, {
            error: err.message,
        });
    }
    return { statusCode: 200, body: 'Disconnected' };
};
exports.handler = handler;
//# sourceMappingURL=disconnect.js.map
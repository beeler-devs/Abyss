"use strict";
/**
 * WebSocket push service using API Gateway Management API.
 * Sends WireEvents back to connected iOS clients.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.initApiGwClient = initApiGwClient;
exports.getApiGwClient = getApiGwClient;
exports.setApiGwClient = setApiGwClient;
exports.sendToConnection = sendToConnection;
exports.sendEventsToConnection = sendEventsToConnection;
const client_apigatewaymanagementapi_1 = require("@aws-sdk/client-apigatewaymanagementapi");
const logger_1 = require("../utils/logger");
let apiGwClient = null;
/**
 * Initialize the API Gateway Management API client.
 * Must be called with the WebSocket API endpoint URL.
 */
function initApiGwClient(endpoint) {
    apiGwClient = new client_apigatewaymanagementapi_1.ApiGatewayManagementApiClient({
        endpoint,
    });
}
/**
 * Get the current client (for testing injection).
 */
function getApiGwClient() {
    if (!apiGwClient) {
        throw new Error('API Gateway Management client not initialized. Call initApiGwClient() first.');
    }
    return apiGwClient;
}
/**
 * Set a custom client (for testing).
 */
function setApiGwClient(client) {
    apiGwClient = client;
}
/**
 * Send a WireEvent to a specific WebSocket connection.
 * Returns false if the connection is gone (stale).
 */
async function sendToConnection(connectionId, event) {
    const client = getApiGwClient();
    const payload = JSON.stringify(event);
    try {
        await client.send(new client_apigatewaymanagementapi_1.PostToConnectionCommand({
            ConnectionId: connectionId,
            Data: Buffer.from(payload),
        }));
        logger_1.logger.debug('Event sent to connection', { connectionId }, {
            eventKind: Object.keys(event.kind)[0],
        });
        return true;
    }
    catch (err) {
        if (err instanceof client_apigatewaymanagementapi_1.GoneException) {
            logger_1.logger.warn('Connection gone (stale)', { connectionId });
            return false;
        }
        logger_1.logger.error('Failed to send to connection', { connectionId }, {
            error: err.message,
        });
        throw err;
    }
}
/**
 * Send multiple events to a connection in order.
 */
async function sendEventsToConnection(connectionId, events) {
    for (const event of events) {
        const ok = await sendToConnection(connectionId, event);
        if (!ok) {
            logger_1.logger.warn('Stopping event send — connection gone', { connectionId });
            break;
        }
    }
}
//# sourceMappingURL=websocket.js.map
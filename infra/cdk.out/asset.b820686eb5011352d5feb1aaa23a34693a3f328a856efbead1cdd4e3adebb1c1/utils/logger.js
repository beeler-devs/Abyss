"use strict";
/**
 * Structured logger for CloudWatch.
 * Every log line includes sessionId and requestId for tracing.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.logger = void 0;
function formatLog(level, message, ctx, extra) {
    return JSON.stringify({
        level,
        message,
        ...ctx,
        ...extra,
        ts: new Date().toISOString(),
    });
}
exports.logger = {
    info(message, ctx = {}, extra) {
        console.log(formatLog('INFO', message, ctx, extra));
    },
    warn(message, ctx = {}, extra) {
        console.warn(formatLog('WARN', message, ctx, extra));
    },
    error(message, ctx = {}, extra) {
        console.error(formatLog('ERROR', message, ctx, extra));
    },
    debug(message, ctx = {}, extra) {
        if (process.env.LOG_LEVEL === 'DEBUG') {
            console.debug(formatLog('DEBUG', message, ctx, extra));
        }
    },
};
//# sourceMappingURL=logger.js.map
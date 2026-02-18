/**
 * Structured logger for CloudWatch.
 * Every log line includes sessionId and requestId for tracing.
 */
export interface LogContext {
    sessionId?: string;
    connectionId?: string;
    requestId?: string;
    callId?: string;
}
export declare const logger: {
    info(message: string, ctx?: LogContext, extra?: Record<string, unknown>): void;
    warn(message: string, ctx?: LogContext, extra?: Record<string, unknown>): void;
    error(message: string, ctx?: LogContext, extra?: Record<string, unknown>): void;
    debug(message: string, ctx?: LogContext, extra?: Record<string, unknown>): void;
};
//# sourceMappingURL=logger.d.ts.map
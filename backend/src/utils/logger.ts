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

function formatLog(level: string, message: string, ctx: LogContext, extra?: Record<string, unknown>): string {
  return JSON.stringify({
    level,
    message,
    ...ctx,
    ...extra,
    ts: new Date().toISOString(),
  });
}

export const logger = {
  info(message: string, ctx: LogContext = {}, extra?: Record<string, unknown>): void {
    console.log(formatLog('INFO', message, ctx, extra));
  },
  warn(message: string, ctx: LogContext = {}, extra?: Record<string, unknown>): void {
    console.warn(formatLog('WARN', message, ctx, extra));
  },
  error(message: string, ctx: LogContext = {}, extra?: Record<string, unknown>): void {
    console.error(formatLog('ERROR', message, ctx, extra));
  },
  debug(message: string, ctx: LogContext = {}, extra?: Record<string, unknown>): void {
    if (process.env.LOG_LEVEL === 'DEBUG') {
      console.debug(formatLog('DEBUG', message, ctx, extra));
    }
  },
};

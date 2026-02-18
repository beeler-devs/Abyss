interface LogContext {
  sessionId?: string;
  eventId?: string;
  callId?: string;
  trace?: string;
}

function contextPrefix(context?: LogContext): string {
  if (!context) {
    return "";
  }

  const parts: string[] = [];
  if (context.sessionId) parts.push(`session=${context.sessionId}`);
  if (context.eventId) parts.push(`event=${context.eventId}`);
  if (context.callId) parts.push(`call=${context.callId}`);
  if (context.trace) parts.push(`trace=${context.trace}`);

  return parts.length ? `[${parts.join(" ")}] ` : "";
}

export const logger = {
  info(message: string, context?: LogContext): void {
    console.log(`${new Date().toISOString()} INFO ${contextPrefix(context)}${message}`);
  },

  warn(message: string, context?: LogContext): void {
    console.warn(`${new Date().toISOString()} WARN ${contextPrefix(context)}${message}`);
  },

  error(message: string, context?: LogContext): void {
    console.error(`${new Date().toISOString()} ERROR ${contextPrefix(context)}${message}`);
  },
};

function contextPrefix(context) {
    if (!context) {
        return "";
    }
    const parts = [];
    if (context.sessionId)
        parts.push(`session=${context.sessionId}`);
    if (context.eventId)
        parts.push(`event=${context.eventId}`);
    if (context.callId)
        parts.push(`call=${context.callId}`);
    if (context.trace)
        parts.push(`trace=${context.trace}`);
    return parts.length ? `[${parts.join(" ")}] ` : "";
}
export const logger = {
    info(message, context) {
        console.log(`${new Date().toISOString()} INFO ${contextPrefix(context)}${message}`);
    },
    warn(message, context) {
        console.warn(`${new Date().toISOString()} WARN ${contextPrefix(context)}${message}`);
    },
    error(message, context) {
        console.error(`${new Date().toISOString()} ERROR ${contextPrefix(context)}${message}`);
    },
};

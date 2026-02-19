import "dotenv/config";
import { WebSocketServer, WebSocket } from "ws";
import { ConductorService } from "./core/conductorService.js";
import { parseIncomingEvent, makeEvent } from "./core/events.js";
import { logger } from "./core/logger.js";
import { buildProvider } from "./providers/index.js";
const PORT = parseInteger(process.env.PORT, 8080);
const MODEL_PROVIDER = (process.env.MODEL_PROVIDER ?? "anthropic").toLowerCase() === "bedrock" ? "bedrock" : "anthropic";
const MAX_EVENT_BYTES = parseInteger(process.env.MAX_EVENT_BYTES, 65_536);
const MAX_TURNS = parseInteger(process.env.MAX_TURNS, 20);
const SESSION_RATE_LIMIT_PER_MIN = parseInteger(process.env.SESSION_RATE_LIMIT_PER_MIN, 30);
const provider = buildProvider({
    modelProvider: MODEL_PROVIDER,
    anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    anthropicModel: process.env.ANTHROPIC_MODEL ?? "claude-3-5-haiku-latest",
    anthropicMaxTokens: parseInteger(process.env.ANTHROPIC_MAX_TOKENS, 512),
    anthropicPartialDelayMs: parseInteger(process.env.ANTHROPIC_PARTIAL_DELAY_MS, 60),
    bedrockModelId: process.env.BEDROCK_MODEL_ID ?? "amazon.nova-lite-v1:0",
    awsRegion: process.env.AWS_REGION ?? "us-east-1",
});
const conductor = new ConductorService(provider, {
    maxTurns: MAX_TURNS,
    rateLimitPerMinute: SESSION_RATE_LIMIT_PER_MIN,
});
const wss = new WebSocketServer({
    port: PORT,
    path: "/ws",
    maxPayload: MAX_EVENT_BYTES,
});
logger.info(`Abyss conductor server listening on ws://localhost:${PORT}/ws using provider=${provider.name}`);
wss.on("connection", (socket, request) => {
    const limiter = conductor.createRateLimiter();
    let connectionSessionId = null;
    logger.info("client connected", {
        trace: request.socket.remoteAddress ?? "unknown",
    });
    socket.on("message", async (raw) => {
        const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw);
        if (!limiter.allow()) {
            if (connectionSessionId) {
                safeSend(socket, makeEvent("error", connectionSessionId, {
                    code: "rate_limited",
                    message: "Too many events for this session in the last minute.",
                }));
            }
            logger.warn("rate limit hit for socket");
            return;
        }
        const parsed = parseIncomingEvent(text, MAX_EVENT_BYTES);
        if (!parsed.event) {
            const fallbackSessionId = connectionSessionId ?? "unknown";
            safeSend(socket, makeEvent("error", fallbackSessionId, {
                code: "invalid_event",
                message: parsed.error ?? "Invalid event envelope",
            }));
            return;
        }
        const event = parsed.event;
        if (connectionSessionId && connectionSessionId !== event.sessionId) {
            safeSend(socket, makeEvent("error", connectionSessionId, {
                code: "session_mismatch",
                message: "Each connection may only use one sessionId.",
            }));
            return;
        }
        connectionSessionId = event.sessionId;
        logger.info(`inbound ${event.type}`, {
            sessionId: event.sessionId,
            eventId: event.id,
        });
        await conductor.handleEvent(event, (outbound) => {
            logger.info(`outbound ${outbound.type}`, {
                sessionId: outbound.sessionId,
                eventId: outbound.id,
                callId: typeof outbound.payload.callId === "string" ? outbound.payload.callId : undefined,
            });
            safeSend(socket, outbound);
        });
    });
    socket.on("close", () => {
        logger.info("client disconnected", {
            sessionId: connectionSessionId ?? undefined,
        });
    });
    socket.on("error", (error) => {
        logger.warn(`socket error: ${error.message}`, {
            sessionId: connectionSessionId ?? undefined,
        });
    });
});
function parseInteger(raw, fallback) {
    if (!raw) {
        return fallback;
    }
    const value = Number.parseInt(raw, 10);
    if (Number.isNaN(value) || value <= 0) {
        return fallback;
    }
    return value;
}
function safeSend(socket, event) {
    if (socket.readyState !== WebSocket.OPEN) {
        return;
    }
    try {
        socket.send(JSON.stringify(event));
    }
    catch (error) {
        const message = error instanceof Error ? error.message : "unknown send error";
        logger.warn(`failed to send websocket event: ${message}`);
    }
}

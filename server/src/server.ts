import "dotenv/config";

import http from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { ConductorService } from "./core/conductorService.js";
import { parseIncomingEvent, makeEvent } from "./core/events.js";
import { logger } from "./core/logger.js";
import { CursorClient } from "./integrations/cursorClient.js";
import { verifyCursorWebhookSignature } from "./integrations/cursorWebhook.js";
import { buildProvider } from "./providers/index.js";

const PORT = parseInteger(process.env.PORT, 8080);
const MODEL_PROVIDER = (process.env.MODEL_PROVIDER ?? "anthropic").toLowerCase() === "bedrock" ? "bedrock" : "anthropic";
const MAX_EVENT_BYTES = parseInteger(process.env.MAX_EVENT_BYTES, 65_536);
const MAX_TURNS = parseInteger(process.env.MAX_TURNS, 20);
const SESSION_RATE_LIMIT_PER_MIN = parseInteger(process.env.SESSION_RATE_LIMIT_PER_MIN, 30);
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID ?? "";
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET ?? "";
const CURSOR_API_KEY = process.env.CURSOR_API_KEY ?? "";
const CURSOR_WEBHOOK_URL = process.env.CURSOR_WEBHOOK_URL ?? "";
const CURSOR_WEBHOOK_SECRET = process.env.CURSOR_WEBHOOK_SECRET ?? "";
const MAX_WEBHOOK_BYTES = parseInteger(process.env.CURSOR_WEBHOOK_MAX_BYTES, 512_000);

const provider = buildProvider({
  modelProvider: MODEL_PROVIDER,
  anthropicApiKey: process.env.ANTHROPIC_API_KEY,
  anthropicModel: process.env.ANTHROPIC_MODEL ?? "claude-haiku-4-5",
  anthropicMaxTokens: parseInteger(process.env.ANTHROPIC_MAX_TOKENS, 512),
  anthropicPartialDelayMs: parseInteger(process.env.ANTHROPIC_PARTIAL_DELAY_MS, 60),
  bedrockModelId: process.env.BEDROCK_MODEL_ID ?? "amazon.nova-lite-v1:0",
  awsRegion: process.env.AWS_REGION ?? "us-east-1",
});

const conductor = new ConductorService(
  provider,
  {
    maxTurns: MAX_TURNS,
    rateLimitPerMinute: SESSION_RATE_LIMIT_PER_MIN,
  },
  {
    cursorClient: new CursorClient({
      apiKey: CURSOR_API_KEY,
      webhookUrl: CURSOR_WEBHOOK_URL,
      webhookSecret: CURSOR_WEBHOOK_SECRET,
    }),
  },
);

const sessionSockets = new Map<string, WebSocket>();

// HTTP server handles /github/exchange for OAuth token exchange and upgrade to WebSocket.
const httpServer = http.createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/github/exchange") {
    await handleGithubExchange(req, res);
    return;
  }
  if (req.method === "POST" && req.url === "/cursor/webhook") {
    await handleCursorWebhook(req, res);
    return;
  }
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not_found" }));
});

const wss = new WebSocketServer({
  server: httpServer,
  path: "/ws",
  maxPayload: MAX_EVENT_BYTES,
});

httpServer.listen(PORT, () => {
  logger.info(`Abyss conductor server listening on port ${PORT} using provider=${provider.name}`);
});

wss.on("connection", (socket, request) => {
  const limiter = conductor.createRateLimiter();
  let connectionSessionId: string | null = null;

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
    sessionSockets.set(connectionSessionId, socket);

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
      emitToSession(outbound, socket);
    });
  });

  socket.on("close", () => {
    if (connectionSessionId && sessionSockets.get(connectionSessionId) === socket) {
      sessionSockets.delete(connectionSessionId);
    }
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

async function handleCursorWebhook(
  req: http.IncomingMessage,
  res: http.ServerResponse,
): Promise<void> {
  if (!CURSOR_WEBHOOK_SECRET) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "cursor_webhook_not_configured" }));
    return;
  }

  const signatureHeader = req.headers["x-webhook-signature"];
  const signature = Array.isArray(signatureHeader) ? signatureHeader[0] : signatureHeader;

  let rawBody = "";
  for await (const chunk of req) {
    rawBody += chunk;
    if (rawBody.length > MAX_WEBHOOK_BYTES) {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large" }));
      return;
    }
  }

  if (!verifyCursorWebhookSignature(rawBody, signature, CURSOR_WEBHOOK_SECRET)) {
    res.writeHead(401, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_signature" }));
    return;
  }

  let payload: Record<string, unknown>;
  try {
    const parsed = JSON.parse(rawBody) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("invalid_payload");
    }
    payload = parsed as Record<string, unknown>;
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_json" }));
    return;
  }

  const result = await conductor.handleCursorWebhook(payload, (event) => {
    logger.info(`outbound ${event.type}`, {
      sessionId: event.sessionId,
      eventId: event.id,
      trace: "cursor.webhook",
    });
    emitToSession(event);
  });

  res.writeHead(result.statusCode, { "Content-Type": "application/json" });
  res.end(JSON.stringify(result.payload));
}

async function handleGithubExchange(
  req: http.IncomingMessage,
  res: http.ServerResponse,
): Promise<void> {
  if (!GITHUB_CLIENT_ID || !GITHUB_CLIENT_SECRET) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "github_not_configured" }));
    return;
  }

  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 4096) {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large" }));
      return;
    }
  }

  let code: string;
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    if (typeof parsed.code !== "string" || !parsed.code) {
      throw new Error("missing code");
    }
    code = parsed.code;
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_request", message: "Body must be JSON with a 'code' string." }));
    return;
  }

  try {
    const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
      },
      body: JSON.stringify({
        client_id: GITHUB_CLIENT_ID,
        client_secret: GITHUB_CLIENT_SECRET,
        code,
        redirect_uri: "abyss://oauth-callback",
      }),
      signal: AbortSignal.timeout(10_000),
    });

    const payload = await tokenResponse.json() as Record<string, unknown>;

    if (typeof payload.error === "string") {
      logger.warn(`github token exchange error: ${payload.error}`);
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: payload.error, description: payload.error_description }));
      return;
    }

    const token = payload.access_token;
    if (typeof token !== "string" || !token) {
      throw new Error("no access_token in github response");
    }

    logger.info("github token exchange successful");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ token }));
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    logger.warn(`github token exchange failed: ${message}`);
    res.writeHead(500, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "exchange_failed", message }));
  }
}

function parseInteger(raw: string | undefined, fallback: number): number {
  if (!raw) {
    return fallback;
  }

  const value = Number.parseInt(raw, 10);
  if (Number.isNaN(value) || value <= 0) {
    return fallback;
  }
  return value;
}

function emitToSession(event: { sessionId: string }, preferredSocket?: WebSocket): void {
  const socket = preferredSocket && preferredSocket.readyState === WebSocket.OPEN
    ? preferredSocket
    : sessionSockets.get(event.sessionId);
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }
  safeSend(socket, event);
}

function safeSend(socket: WebSocket, event: object): void {
  if (socket.readyState !== WebSocket.OPEN) {
    return;
  }

  try {
    socket.send(JSON.stringify(event));
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown send error";
    logger.warn(`failed to send websocket event: ${message}`);
  }
}

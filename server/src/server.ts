import "dotenv/config";

import http from "node:http";
import { WebSocketServer, WebSocket } from "ws";

import { BridgeStateStore, BridgeCapabilities } from "./bridge/state.js";
import { BridgeToolRouter } from "./bridge/toolRouter.js";
import { ConductorService } from "./core/conductorService.js";
import { parseIncomingEvent, makeEvent } from "./core/events.js";
import { logger } from "./core/logger.js";
import { EventEnvelope } from "./core/types.js";
import { CursorClient } from "./integrations/cursorClient.js";
import { verifyCursorWebhookSignature } from "./integrations/cursorWebhook.js";
import { GmailClient } from "./integrations/gmailClient.js";
import { exchangeGoogleCode } from "./integrations/gmailAuth.js";
import { buildProvider } from "./providers/index.js";
import { MemoryService } from "./core/memory/memoryService.js";
import { BedrockNovaSonicVoiceProvider } from "./voice/bedrockNovaSonicVoiceProvider.js";
import { VoiceProvider } from "./voice/types.js";

const PORT = parseInteger(process.env.PORT, 8080);
const MODEL_PROVIDER = (process.env.MODEL_PROVIDER ?? "bedrock").toLowerCase() === "anthropic" ? "anthropic" : "bedrock";
const VOICE_PROVIDER = (process.env.VOICE_PROVIDER ?? "nova-sonic").toLowerCase();
const MAX_EVENT_BYTES = parseInteger(process.env.MAX_EVENT_BYTES, 65_536);
const MAX_TURNS = parseInteger(process.env.MAX_TURNS, 20);
const SESSION_RATE_LIMIT_PER_MIN = parseInteger(process.env.SESSION_RATE_LIMIT_PER_MIN, 30);
const TRANSCRIPT_TRACE_MAX_ENTRIES = parseInteger(process.env.TRANSCRIPT_TRACE_MAX_ENTRIES, 120);
const VERBOSE_TOOL_ROUTING_LOGS = parseBoolean(process.env.VERBOSE_TOOL_ROUTING_LOGS, false);
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID ?? "";
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET ?? "";
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID ?? "";
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET ?? "";
const CURSOR_API_KEY = process.env.CURSOR_API_KEY ?? "";
const CURSOR_WEBHOOK_URL = process.env.CURSOR_WEBHOOK_URL ?? "";
const CURSOR_WEBHOOK_SECRET = process.env.CURSOR_WEBHOOK_SECRET ?? "";
const MAX_WEBHOOK_BYTES = parseInteger(process.env.CURSOR_WEBHOOK_MAX_BYTES, 512_000);
const BRIDGE_PAIRING_TTL_MS = parseInteger(process.env.BRIDGE_PAIRING_TTL_MS, 5 * 60_000);
const MEMORY_ENABLED = parseBoolean(process.env.MEMORY_ENABLED, false);
const MEMORY_S3_BUCKET = process.env.MEMORY_S3_BUCKET ?? "";
const MEMORY_S3_PREFIX = process.env.MEMORY_S3_PREFIX ?? "memories/";
const MEMORY_KB_ID = process.env.MEMORY_KB_ID ?? "";
const MEMORY_KB_DATA_SOURCE_ID = process.env.MEMORY_KB_DATA_SOURCE_ID ?? "";
const MEMORY_RETRIEVE_TIMEOUT_MS = parseInteger(process.env.MEMORY_RETRIEVE_TIMEOUT_MS, 1500);
const MEMORY_MAX_INJECTED_CHARS = parseInteger(process.env.MEMORY_MAX_INJECTED_CHARS, 900);
const MEMORY_RECENT_COUNT = parseInteger(process.env.MEMORY_RECENT_COUNT, 3);
const MEMORY_SUMMARY_MODEL_ID = process.env.MEMORY_SUMMARY_MODEL_ID ?? "us.amazon.nova-2-lite-v1:0";

const provider = buildProvider({
  modelProvider: MODEL_PROVIDER,
  anthropicApiKey: process.env.ANTHROPIC_API_KEY,
  anthropicModel: process.env.ANTHROPIC_MODEL ?? "claude-haiku-4-5",
  anthropicMaxTokens: parseInteger(process.env.ANTHROPIC_MAX_TOKENS, 512),
  anthropicPartialDelayMs: parseInteger(process.env.ANTHROPIC_PARTIAL_DELAY_MS, 60),
  bedrockTextModelId: process.env.BEDROCK_TEXT_MODEL_ID ?? "us.amazon.nova-2-lite-v1:0",
  bedrockMaxTokens: parseInteger(process.env.BEDROCK_MAX_TOKENS, 512),
  bedrockPartialDelayMs: parseInteger(process.env.BEDROCK_PARTIAL_DELAY_MS, 60),
  awsRegion: process.env.AWS_REGION ?? "us-east-1",
});
const voiceProvider: VoiceProvider | null = VOICE_PROVIDER === "nova-sonic"
  ? new BedrockNovaSonicVoiceProvider({
    modelId: process.env.BEDROCK_SONIC_MODEL_ID ?? "amazon.nova-sonic-v1:0",
    region: process.env.AWS_REGION ?? "us-east-1",
    voiceId: process.env.BEDROCK_SONIC_VOICE_ID ?? "tiffany",
    enableTools: process.env.BEDROCK_SONIC_ENABLE_TOOLS !== "false",
  })
  : null;

type ConnectionKind = "unknown" | "ios" | "bridge";

interface ConnectionContext {
  kind: ConnectionKind;
  sessionId?: string;
  deviceId?: string;
}

const iosSocketsBySession = new Map<string, WebSocket>();
const bridgeSocketsByDeviceId = new Map<string, WebSocket>();
const socketContexts = new WeakMap<WebSocket, ConnectionContext>();

const bridgeState = new BridgeStateStore(BRIDGE_PAIRING_TTL_MS);

const bridgeRouter = new BridgeToolRouter({
  state: bridgeState,
  sendToBridge: (deviceId, event) => {
    const socket = bridgeSocketsByDeviceId.get(deviceId);
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return false;
    }
    safeSend(socket, event);
    return true;
  },
  emitToIOS: (event) => {
    emitToSession(event);
  },
  verboseToolRoutingLogs: VERBOSE_TOOL_ROUTING_LOGS,
});

const memoryService = MEMORY_ENABLED && MEMORY_S3_BUCKET
  ? new MemoryService({
      enabled: true,
      s3Bucket: MEMORY_S3_BUCKET,
      s3Prefix: MEMORY_S3_PREFIX,
      knowledgeBaseId: MEMORY_KB_ID || undefined,
      knowledgeBaseDataSourceId: MEMORY_KB_DATA_SOURCE_ID || undefined,
      awsRegion: process.env.AWS_REGION ?? "us-east-1",
      summaryModelId: MEMORY_SUMMARY_MODEL_ID,
      retrieveTimeoutMs: MEMORY_RETRIEVE_TIMEOUT_MS,
      maxInjectedChars: MEMORY_MAX_INJECTED_CHARS,
      recentMemoryCount: MEMORY_RECENT_COUNT,
    })
  : undefined;

const conductor = new ConductorService(
  provider,
  {
    maxTurns: MAX_TURNS,
    rateLimitPerMinute: SESSION_RATE_LIMIT_PER_MIN,
    traceMaxEntries: TRANSCRIPT_TRACE_MAX_ENTRIES,
  },
  {
    cursorClient: new CursorClient({
      apiKey: CURSOR_API_KEY,
      webhookUrl: CURSOR_WEBHOOK_URL,
      webhookSecret: CURSOR_WEBHOOK_SECRET,
    }),
    gmailClient: new GmailClient({
      googleClientId: GOOGLE_CLIENT_ID,
      googleClientSecret: GOOGLE_CLIENT_SECRET,
    }),
    bridgeToolExecutor: async (request) => bridgeRouter.execute(request),
    bridgeToolAvailability: (sessionId, toolName) => {
      let devices = bridgeState
        .getSessionDevices(sessionId)
        .filter((device) => device.status === "online");
      // Session churn resilience: if no session-matched devices, fall back to global online
      // devices (mirrors resolveDeviceForTool behaviour so the LLM sees bridge tools after
      // the iOS app restarts with a new sessionId).
      if (devices.length === 0) {
        devices = bridgeState.getOnlineDevices();
      }
      return devices.some((device) => bridgeDeviceSupportsTool(device.capabilities, toolName));
    },
    verboseToolRoutingLogs: VERBOSE_TOOL_ROUTING_LOGS,
    memoryService,
  },
);

// HTTP server handles /github/exchange for OAuth token exchange and upgrade to WebSocket.
const httpServer = http.createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/github/exchange") {
    await handleGithubExchange(req, res);
    return;
  }
  if (req.method === "POST" && req.url === "/google/exchange") {
    await handleGoogleExchange(req, res);
    return;
  }
  if (req.method === "POST" && req.url === "/cursor/webhook") {
    await handleCursorWebhook(req, res);
    return;
  }
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      ok: true,
      provider: provider.name,
      voiceProvider: VOICE_PROVIDER,
      region: process.env.AWS_REGION ?? "us-east-1",
    }));
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
  socketContexts.set(socket, { kind: "unknown" });

  logger.info("client connected", {
    trace: request.socket.remoteAddress ?? "unknown",
  });

  socket.on("message", async (raw) => {
    const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw);

    const parsed = parseIncomingEvent(text, MAX_EVENT_BYTES);
    if (!parsed.event) {
      const context = socketContexts.get(socket);
      const fallbackSessionId = context?.sessionId ?? "unknown";
      safeSend(socket, makeEvent("error", fallbackSessionId, {
        code: "invalid_event",
        message: parsed.error ?? "Invalid event envelope",
      }));
      return;
    }

    const event = parsed.event;

    // High-frequency event types exempt from rate limiting:
    // - audio stream chunks (~10/sec from mic)
    // - assistant speech partials (streamed TTS events)
    // - tool results (responses to server-initiated tool calls, can burst during speech streaming)
    const isAudioStream = event.type.startsWith("user.audio.stream.");
    const isSpeechStream = event.type.startsWith("assistant.speech.");
    const isToolResult = event.type === "tool.result";
    if (!isAudioStream && !isSpeechStream && !isToolResult && !limiter.allow()) {
      const context = socketContexts.get(socket);
      const fallbackSessionId = context?.sessionId ?? "unknown";
      safeSend(socket, makeEvent("error", fallbackSessionId, {
        code: "rate_limited",
        message: "Too many events for this session in the last minute.",
      }));
      logger.warn("rate limit hit for socket");
      return;
    }

    const context = socketContexts.get(socket) ?? { kind: "unknown" };

    if (event.type === "bridge.register") {
      await handleBridgeRegister(socket, event, context);
      return;
    }

    if (context.kind === "bridge") {
      const handled = bridgeRouter.handleBridgeEvent(event, context.deviceId);
      if (!handled) {
        logger.warn("bridge event had no pending route", {
          type: event.type,
          callId: typeof event.payload.callId === "string" ? event.payload.callId : undefined,
          deviceId: context.deviceId,
        });
      }
      return;
    }

    if (event.type === "bridge.pair.request") {
      handleBridgePairRequest(socket, event, context);
      return;
    }

    // Everything else on non-bridge connections is treated as iOS/client traffic.
    if (context.sessionId && context.sessionId !== event.sessionId) {
      safeSend(socket, makeEvent("error", context.sessionId, {
        code: "session_mismatch",
        message: "Each connection may only use one sessionId.",
      }));
      return;
    }

    context.kind = "ios";
    context.sessionId = event.sessionId;
    socketContexts.set(socket, context);
    iosSocketsBySession.set(event.sessionId, socket);

    if (!isAudioStream) {
      logger.info(`inbound ${event.type}`, {
        sessionId: event.sessionId,
        eventId: event.id,
      });
    }

    if (event.type === "session.start") {
      emitBridgeStatusSnapshot(event.sessionId, socket);
    }

    if (event.type === "audio.output.interrupted") {
      if (voiceProvider) {
        await voiceProvider.interrupt(event.sessionId);
      }
      const cancelled = await bridgeRouter.cancelActiveCommand(event.sessionId);
      logger.info("audio interrupt bridge cancel attempted", {
        sessionId: event.sessionId,
        cancelled,
      });
    }

    if (voiceProvider && event.type === "user.audio.stream.start") {
      await voiceProvider.startStream(event.sessionId, {
        emit: (outbound) => emitToSession(outbound),
        listTools: (sessionId) => conductor.listAvailableTools(sessionId),
        executeTool: async (sessionId, toolCall, emit) => conductor.executeDirectToolCall(sessionId, toolCall, emit),
      });
      return;
    }

    if (voiceProvider && event.type === "user.audio.stream.chunk") {
      const chunk = typeof event.payload.audio === "string" ? event.payload.audio : "";
      if (!chunk) {
        safeSend(socket, makeEvent("error", event.sessionId, {
          code: "invalid_audio_chunk",
          message: "user.audio.stream.chunk must include payload.audio",
        }));
        return;
      }
      await voiceProvider.appendAudioChunk(event.sessionId, chunk);
      return;
    }

    if (voiceProvider && event.type === "user.audio.stream.end") {
      await voiceProvider.endStream(event.sessionId);
      return;
    }

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
    const context = socketContexts.get(socket);

    if (context?.kind === "ios" && context.sessionId) {
      if (iosSocketsBySession.get(context.sessionId) === socket) {
        iosSocketsBySession.delete(context.sessionId);
        void conductor.finalizeSession(context.sessionId);
      }
      if (voiceProvider) {
        void voiceProvider.closeSession(context.sessionId);
      }
    }

    if (context?.kind === "bridge" && context.deviceId) {
      if (bridgeSocketsByDeviceId.get(context.deviceId) === socket) {
        bridgeSocketsByDeviceId.delete(context.deviceId);
      }

      const updated = bridgeState.markDeviceOffline(context.deviceId);
      if (updated) {
        bridgeRouter.failPendingForDevice(updated.deviceId);
        emitToSession(makeEvent("bridge.status", updated.sessionId, {
          deviceId: updated.deviceId,
          status: "offline",
          lastSeen: updated.lastSeen,
        }));
      }
    }

    logger.info("client disconnected", {
      sessionId: context?.sessionId,
      deviceId: context?.deviceId,
      kind: context?.kind,
    });
  });

  socket.on("error", (error) => {
    const context = socketContexts.get(socket);
    logger.warn(`socket error: ${error.message}`, {
      sessionId: context?.sessionId,
      deviceId: context?.deviceId,
      kind: context?.kind,
    });
  });
});

async function handleBridgeRegister(
  socket: WebSocket,
  event: EventEnvelope,
  context: ConnectionContext,
): Promise<void> {
  const payload = event.payload;

  const pairingCode = readString(payload, "pairingCode");
  const deviceId = readString(payload, "deviceId");
  const deviceName = readString(payload, "deviceName");
  const workspaceRoot = readString(payload, "workspaceRoot");
  const workspaceRoots = readStringArray(payload, "workspaceRoots");
  const capabilities = readCapabilities(payload.capabilities);

  if (!pairingCode || !deviceId || !deviceName || !workspaceRoot || !capabilities) {
    safeSend(socket, makeEvent("error", event.sessionId, {
      code: "bridge_register_invalid_payload",
      message: "bridge.register requires pairingCode, deviceId, deviceName, workspaceRoot, capabilities",
    }));
    return;
  }

  const wasAlreadyPaired = bridgeState.getDevice(deviceId)?.status === "online";

  const registration = bridgeState.registerBridge({
    pairingCode,
    deviceId,
    deviceName,
    workspaceRoot,
    workspaceRoots,
    capabilities,
  });

  if (!registration.device) {
    safeSend(socket, makeEvent("error", event.sessionId, {
      code: registration.error ?? "bridge_register_failed",
      message: "Bridge pairing code not found or expired.",
    }));
    return;
  }

  context.kind = "bridge";
  context.deviceId = deviceId;
  context.sessionId = registration.device.sessionId;
  socketContexts.set(socket, context);

  bridgeSocketsByDeviceId.set(deviceId, socket);

  safeSend(socket, makeEvent("bridge.registered", event.sessionId, {
    deviceId,
    sessionId: registration.device.sessionId,
    status: "online",
  }));

  // Only emit bridge.paired/status to iOS on initial pair — not on 8s heartbeat re-registers
  if (!wasAlreadyPaired) {
    emitToSession(makeEvent("bridge.paired", registration.device.sessionId, {
      deviceId: registration.device.deviceId,
      deviceName: registration.device.deviceName,
      status: "online",
    }));

    emitToSession(makeEvent("bridge.status", registration.device.sessionId, {
      deviceId: registration.device.deviceId,
      status: "online",
      lastSeen: registration.device.lastSeen,
    }));
  }

  logger.info(wasAlreadyPaired ? "bridge heartbeat" : "bridge registered", {
    sessionId: registration.device.sessionId,
    deviceId,
    deviceName,
  });
}

function handleBridgePairRequest(
  socket: WebSocket,
  event: EventEnvelope,
  context: ConnectionContext,
): void {
  const pairingCode = readString(event.payload, "pairingCode");
  const deviceName = readString(event.payload, "deviceName");

  if (!pairingCode) {
    safeSend(socket, makeEvent("error", event.sessionId, {
      code: "bridge_pairing_code_missing",
      message: "bridge.pair.request requires pairingCode",
    }));
    return;
  }

  bridgeState.createPairingRequest(event.sessionId, pairingCode, deviceName);

  context.kind = "ios";
  context.sessionId = event.sessionId;
  socketContexts.set(socket, context);
  iosSocketsBySession.set(event.sessionId, socket);

  safeSend(socket, makeEvent("bridge.pair.pending", event.sessionId, {
    pairingCode: pairingCode.trim().toUpperCase(),
    expiresInSec: Math.floor(BRIDGE_PAIRING_TTL_MS / 1000),
  }));

  logger.info("bridge pairing requested", {
    sessionId: event.sessionId,
    pairingCode: pairingCode.trim().toUpperCase(),
  });
}

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

  const bodyChunks: Buffer[] = [];
  let bodyLength = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bodyLength += buf.length;
    if (bodyLength > MAX_WEBHOOK_BYTES) {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large" }));
      return;
    }
    bodyChunks.push(buf);
  }
  const rawBody = Buffer.concat(bodyChunks).toString("utf8");

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

async function handleGoogleExchange(
  req: http.IncomingMessage,
  res: http.ServerResponse,
): Promise<void> {
  if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "google_not_configured" }));
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
  let redirectUri: string;
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    if (typeof parsed.code !== "string" || !parsed.code) {
      throw new Error("missing code");
    }
    code = parsed.code;
    redirectUri = typeof parsed.redirectUri === "string" && parsed.redirectUri
      ? parsed.redirectUri
      : "abyss://oauth-callback";
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_request", message: "Body must be JSON with a 'code' string." }));
    return;
  }

  try {
    const tokenResponse = await exchangeGoogleCode(
      code,
      GOOGLE_CLIENT_ID,
      GOOGLE_CLIENT_SECRET,
      redirectUri,
    );

    logger.info("google token exchange successful");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      accessToken: tokenResponse.access_token,
      refreshToken: tokenResponse.refresh_token,
      expiresIn: tokenResponse.expires_in,
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    logger.warn(`google token exchange failed: ${message}`);
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

function parseBoolean(raw: string | undefined, fallback: boolean): boolean {
  if (!raw) {
    return fallback;
  }

  const normalized = raw.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }

  return fallback;
}

function emitToSession(event: { sessionId: string }, preferredSocket?: WebSocket): void {
  const socket = preferredSocket && preferredSocket.readyState === WebSocket.OPEN
    ? preferredSocket
    : iosSocketsBySession.get(event.sessionId);
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }
  safeSend(socket, event);
}

function emitBridgeStatusSnapshot(sessionId: string, preferredSocket?: WebSocket): void {
  const sessionDevices = bridgeState.getSessionDevices(sessionId);
  const devices = sessionDevices.length > 0
    ? sessionDevices
    : bridgeState.getOnlineDevices();

  for (const device of devices) {
    emitToSession(makeEvent("bridge.status", sessionId, {
      deviceId: device.deviceId,
      status: device.status,
      lastSeen: device.lastSeen,
    }), preferredSocket);
  }
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

function readString(payload: Record<string, unknown>, key: string): string | undefined {
  const value = payload[key];
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readCapabilities(value: unknown): BridgeCapabilities | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  const raw = value as Record<string, unknown>;
  const execRun = raw.execRun;
  const readFile = raw.readFile;
  if (typeof execRun !== "boolean" || typeof readFile !== "boolean") {
    return undefined;
  }
  const claudeRun = typeof raw.claudeRun === "boolean" ? raw.claudeRun : false;

  return {
    execRun,
    readFile,
    execStart: optionalBoolean(raw.execStart),
    execCancel: optionalBoolean(raw.execCancel),
    execStatus: optionalBoolean(raw.execStatus),
    execOutputEvents: optionalBoolean(raw.execOutputEvents),
    fsSearch: optionalBoolean(raw.fsSearch),
    fsReadRange: optionalBoolean(raw.fsReadRange),
    fsApplyPatch: optionalBoolean(raw.fsApplyPatch),
    gitStatus: optionalBoolean(raw.gitStatus),
    gitDiff: optionalBoolean(raw.gitDiff),
    gitStage: optionalBoolean(raw.gitStage),
    gitCommit: optionalBoolean(raw.gitCommit),
    gitPush: optionalBoolean(raw.gitPush),
    claudeRun,
  };
}

function readStringArray(payload: Record<string, unknown>, key: string): string[] | undefined {
  const value = payload[key];
  if (!Array.isArray(value)) {
    return undefined;
  }

  const result: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") {
      continue;
    }
    const trimmed = item.trim();
    if (trimmed) {
      result.push(trimmed);
    }
  }

  return result.length > 0 ? result : undefined;
}

function optionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function bridgeDeviceSupportsTool(capabilities: BridgeCapabilities, toolName: string): boolean {
  switch (toolName) {
    case "bridge.exec.run":
      return capabilities.execRun;
    case "bridge.exec.start":
      return capabilities.execStart ?? capabilities.execRun;
    case "bridge.exec.cancel":
      return capabilities.execCancel ?? capabilities.execRun;
    case "bridge.exec.status":
      return capabilities.execStatus ?? capabilities.execRun;
    case "bridge.exec.output.subscribe":
      return capabilities.execOutputEvents ?? capabilities.execRun;
    case "bridge.fs.readFile":
      return capabilities.readFile;
    case "bridge.fs.search":
      return capabilities.fsSearch ?? capabilities.readFile;
    case "bridge.fs.readRange":
      return capabilities.fsReadRange ?? capabilities.readFile;
    case "bridge.fs.applyPatch":
      return capabilities.fsApplyPatch ?? false;
    case "bridge.git.status":
      return capabilities.gitStatus ?? false;
    case "bridge.git.diff":
      return capabilities.gitDiff ?? false;
    case "bridge.git.stage":
      return capabilities.gitStage ?? false;
    case "bridge.git.commit":
      return capabilities.gitCommit ?? false;
    case "bridge.git.push":
      return capabilities.gitPush ?? false;
    case "bridge.claude.run":
      return capabilities.claudeRun ?? false;
    default:
      return false;
  }
}

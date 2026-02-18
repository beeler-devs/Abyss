import crypto from "node:crypto";
import { WebSocket } from "ws";

const baseURL = process.env.SMOKE_WS_URL ?? "ws://localhost:8080/ws";
const sessionId = process.env.SMOKE_SESSION_ID ?? `smoke-${Date.now()}`;
const transcript = process.env.SMOKE_TEXT ?? "hello";

const socket = new WebSocket(baseURL);

socket.on("open", () => {
  console.log(`connected to ${baseURL}`);

  sendEvent("session.start", { sessionId });
  sendEvent("user.audio.transcript.final", {
    text: transcript,
    timestamp: new Date().toISOString(),
    sessionId,
  });
});

socket.on("message", (raw) => {
  const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw);
  try {
    const event = JSON.parse(text);
    const callInfo = event?.payload?.name ? ` (${event.payload.name})` : "";
    console.log(`${event.type}${callInfo}`);
  } catch {
    console.log(text);
  }
});

socket.on("close", () => {
  console.log("socket closed");
  process.exit(0);
});

socket.on("error", (error) => {
  console.error(`socket error: ${error.message}`);
  process.exit(1);
});

setTimeout(() => {
  socket.close();
}, Number(process.env.SMOKE_DURATION_MS ?? 8000));

function sendEvent(type: string, payload: Record<string, unknown>) {
  const envelope = {
    id: crypto.randomUUID(),
    type,
    timestamp: new Date().toISOString(),
    sessionId,
    payload,
  };

  socket.send(JSON.stringify(envelope));
}

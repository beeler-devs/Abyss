import test from "node:test";
import assert from "node:assert/strict";

import { parseIncomingEvent, makeEvent, PROTOCOL_VERSION } from "../src/core/events.js";

test("parseIncomingEvent rejects missing protocolVersion", () => {
  const raw = JSON.stringify({
    id: "evt-1",
    type: "session.start",
    timestamp: new Date().toISOString(),
    sessionId: "session-1",
    payload: { sessionId: "session-1" },
  });

  const parsed = parseIncomingEvent(raw, 1024);
  assert.equal(parsed.event, undefined);
  assert.equal(parsed.error, "missing_protocol_version");
});

test("makeEvent attaches protocolVersion", () => {
  const event = makeEvent("session.started", "session-1", { ok: true });
  assert.equal(event.protocolVersion, PROTOCOL_VERSION);
});

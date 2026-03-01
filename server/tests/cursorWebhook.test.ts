import crypto from "node:crypto";
import test from "node:test";
import assert from "node:assert/strict";

import { verifyCursorWebhookSignature } from "../src/integrations/cursorWebhook.js";

test("verifyCursorWebhookSignature accepts valid hmac-sha256 header", () => {
  const secret = "cursor-webhook-secret";
  const body = JSON.stringify({ eventType: "statusChange", agentId: "agent-123", status: "FINISHED" });
  const signature = crypto
    .createHmac("sha256", secret)
    .update(body, "utf8")
    .digest("hex");

  const valid = verifyCursorWebhookSignature(body, `sha256=${signature}`, secret);
  assert.equal(valid, true);
});

test("verifyCursorWebhookSignature rejects invalid signatures", () => {
  const secret = "cursor-webhook-secret";
  const body = JSON.stringify({ eventType: "statusChange", agentId: "agent-123", status: "ERROR" });

  const valid = verifyCursorWebhookSignature(body, "sha256=deadbeef", secret);
  assert.equal(valid, false);
});

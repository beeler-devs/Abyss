import crypto from "node:crypto";

export function verifyCursorWebhookSignature(
  rawBody: string,
  signatureHeader: string | undefined,
  secret: string | undefined,
): boolean {
  if (!signatureHeader || !secret) {
    return false;
  }

  const expectedHex = crypto
    .createHmac("sha256", secret)
    .update(rawBody, "utf8")
    .digest("hex")
    .toLowerCase();
  const expectedBase64 = crypto
    .createHmac("sha256", secret)
    .update(rawBody, "utf8")
    .digest("base64");

  const providedCandidates = signatureHeader
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
    .map((value) => {
      if (value.toLowerCase().startsWith("sha256=")) {
        return value.slice("sha256=".length);
      }
      return value;
    });

  for (const candidate of providedCandidates) {
    const normalized = candidate.trim();
    if (!normalized) {
      continue;
    }

    if (safeEqual(normalized.toLowerCase(), expectedHex)) {
      return true;
    }

    if (safeEqual(normalized, expectedBase64)) {
      return true;
    }
  }

  return false;
}

function safeEqual(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left, "utf8");
  const rightBuffer = Buffer.from(right, "utf8");
  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

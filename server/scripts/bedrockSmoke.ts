/**
 * Bedrock smoke test — sends one user turn to the Bedrock Nova provider
 * and prints the response. Exits nonzero on any failure.
 *
 * Usage:
 *   AWS_PROFILE=your-profile npm run smoke:bedrock
 */

import "dotenv/config";
import { BedrockNovaProvider } from "../src/providers/bedrockNovaProvider.js";

const modelId = process.env.BEDROCK_TEXT_MODEL_ID ?? "us.amazon.nova-2-lite-v1:0";
const region = process.env.AWS_REGION ?? "us-east-1";

const provider = new BedrockNovaProvider({
  modelId,
  region,
  maxTokens: 256,
  partialDelayMs: 0,
});

console.log(`Bedrock smoke test — model=${modelId} region=${region}\n`);

try {
  const response = await provider.generateResponse([
    { role: "user", content: "Say hello in one sentence." },
  ]);

  console.log("Response text:");
  console.log(response.fullText);

  if (response.toolCalls && response.toolCalls.length > 0) {
    console.log("\nTool calls:");
    console.log(JSON.stringify(response.toolCalls, null, 2));
  }

  console.log("\nSmoke test passed.");
} catch (error) {
  console.error("Smoke test FAILED:");
  console.error(error);
  process.exit(1);
}

import { ConversationTurn, GenerateOptions, ModelProvider, ModelResponse } from "../core/types.js";
import { streamSingle } from "./chunking.js";

export interface BedrockConfig {
  modelId: string;
  region: string;
}

/// Placeholder for future Bedrock Nova integration.
/// Keep this provider scaffolded so switching providers is config-only.
export class BedrockNovaProvider implements ModelProvider {
  readonly name = "bedrock";

  private readonly config: BedrockConfig;

  constructor(config: BedrockConfig) {
    this.config = config;
  }

  async generateResponse(_conversation: ConversationTurn[], _options?: GenerateOptions): Promise<ModelResponse> {
    // TODO(phase3): Integrate AWS Bedrock Runtime InvokeModelWithResponseStream for Nova.
    const fullText = [
      "Bedrock provider is scaffolded but not enabled in this environment.",
      `Configured model: ${this.config.modelId} in ${this.config.region}.`,
      "Set MODEL_PROVIDER=anthropic while Bedrock is rate-limited.",
    ].join(" ");

    return {
      fullText,
      chunks: streamSingle(fullText),
    };
  }
}

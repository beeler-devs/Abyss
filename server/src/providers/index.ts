import { ModelProvider } from "../core/types.js";
import { AnthropicProvider } from "./anthropicProvider.js";
import { BedrockNovaProvider } from "./bedrockNovaProvider.js";

export interface ProviderConfig {
  modelProvider: "anthropic" | "bedrock";
  anthropicApiKey?: string;
  anthropicModel: string;
  anthropicMaxTokens: number;
  anthropicPartialDelayMs: number;
  bedrockModelId: string;
  awsRegion: string;
}

export function buildProvider(config: ProviderConfig): ModelProvider {
  if (config.modelProvider === "bedrock") {
    return new BedrockNovaProvider({
      modelId: config.bedrockModelId,
      region: config.awsRegion,
    });
  }

  if (!config.anthropicApiKey) {
    throw new Error("ANTHROPIC_API_KEY is required when MODEL_PROVIDER=anthropic");
  }

  return new AnthropicProvider({
    apiKey: config.anthropicApiKey,
    model: config.anthropicModel,
    maxTokens: config.anthropicMaxTokens,
    partialDelayMs: config.anthropicPartialDelayMs,
  });
}

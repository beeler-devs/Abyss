import { ModelProvider } from "../core/types.js";
import { ClaudeProvider } from "./claudeProvider.js";

export interface ProviderConfig {
  anthropicApiKey: string;
  model: string;
  proModel?: string;
  maxTokens: number;
}

export function buildProvider(config: ProviderConfig): ModelProvider {
  if (!config.anthropicApiKey) {
    throw new Error("ANTHROPIC_API_KEY is required");
  }

  return new ClaudeProvider({
    apiKey: config.anthropicApiKey,
    model: config.model,
    proModel: config.proModel,
    maxTokens: config.maxTokens,
  });
}

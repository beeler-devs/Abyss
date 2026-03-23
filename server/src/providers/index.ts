import { ModelProvider } from "../core/types.js";
import { ClaudeProvider } from "./claudeProvider.js";

export interface ProviderConfig {
  anthropicApiKey: string;
  model: string;
  maxTokens: number;
}

export function buildProvider(config: ProviderConfig): ModelProvider {
  if (!config.anthropicApiKey) {
    throw new Error("ANTHROPIC_API_KEY is required");
  }

  return new ClaudeProvider({
    apiKey: config.anthropicApiKey,
    model: config.model,
    maxTokens: config.maxTokens,
  });
}

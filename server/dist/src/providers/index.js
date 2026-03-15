import { AnthropicProvider } from "./anthropicProvider.js";
import { BedrockNovaProvider } from "./bedrockNovaProvider.js";
export function buildProvider(config) {
    if (config.modelProvider === "bedrock") {
        return new BedrockNovaProvider({
            modelId: config.bedrockTextModelId,
            region: config.awsRegion,
            maxTokens: config.bedrockMaxTokens,
            partialDelayMs: config.bedrockPartialDelayMs,
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

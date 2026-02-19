import { streamSingle } from "./chunking.js";
/// Placeholder for future Bedrock Nova integration.
/// Keep this provider scaffolded so switching providers is config-only.
export class BedrockNovaProvider {
    name = "bedrock";
    config;
    constructor(config) {
        this.config = config;
    }
    async generateResponse(_conversation, _tools) {
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

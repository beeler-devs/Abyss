import { ConversationTurn, ModelProvider, ModelResponse } from "../core/types.js";
import { chunkText, streamFromChunks } from "./chunking.js";

export interface AnthropicConfig {
  apiKey: string;
  model: string;
  maxTokens: number;
  partialDelayMs: number;
}

interface AnthropicMessageResponse {
  content?: Array<{ type: string; text?: string }>;
}

export class AnthropicProvider implements ModelProvider {
  readonly name = "anthropic";

  private readonly config: AnthropicConfig;

  constructor(config: AnthropicConfig) {
    this.config = config;
  }

  async generateResponse(conversation: ConversationTurn[]): Promise<ModelResponse> {
    const fullText = await this.fetchFullResponse(conversation);
    const chunks = chunkText(fullText, 30, 80);

    return {
      fullText,
      chunks: streamFromChunks(chunks.length ? chunks : [fullText], this.config.partialDelayMs),
    };
  }

  private async fetchFullResponse(conversation: ConversationTurn[]): Promise<string> {
    const messages = conversation
      .filter((turn) => turn.role !== "system")
      .map((turn) => ({
        role: turn.role,
        content: turn.content,
      }));

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.config.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: this.config.model,
        max_tokens: this.config.maxTokens,
        system: [
          "You are the Abyss voice-first coding assistant.",
          "Keep spoken responses concise, practical, and voice-friendly.",
          "Do not ask for speech-to-text tools. The user triggers listening manually.",
          "Avoid markdown tables and avoid long formatting.",
        ].join(" "),
        messages,
      }),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`anthropic_http_${response.status}:${bodyText.slice(0, 120)}`);
    }

    const body = (await response.json()) as AnthropicMessageResponse;
    const text = (body.content ?? [])
      .filter((chunk) => chunk.type === "text" && typeof chunk.text === "string")
      .map((chunk) => chunk.text?.trim() ?? "")
      .join("\n")
      .trim();

    if (!text) {
      return "I heard you. I can continue once the model returns a full response.";
    }

    return text;
  }
}

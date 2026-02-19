import {
  ConversationTurn,
  ModelProvider,
  ModelResponse,
  ToolCallRequest,
  ToolDefinition,
} from "../core/types.js";
import { chunkText, streamFromChunks } from "./chunking.js";

export interface AnthropicConfig {
  apiKey: string;
  model: string;
  maxTokens: number;
  partialDelayMs: number;
}

interface AnthropicMessageResponse {
  content?: unknown;
}

type AnthropicRequestRole = "user" | "assistant";

interface AnthropicTextRequestBlock {
  type: "text";
  text: string;
}

interface AnthropicToolUseRequestBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

interface AnthropicToolResultRequestBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string;
}

type AnthropicRequestBlock =
  | AnthropicTextRequestBlock
  | AnthropicToolUseRequestBlock
  | AnthropicToolResultRequestBlock;

interface AnthropicRequestMessage {
  role: AnthropicRequestRole;
  content: string | AnthropicRequestBlock[];
}

interface FetchResult {
  fullText: string;
  toolCalls: ToolCallRequest[];
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  return value.trim().length ? value : null;
}

export class AnthropicProvider implements ModelProvider {
  readonly name = "anthropic";

  private readonly config: AnthropicConfig;

  constructor(config: AnthropicConfig) {
    this.config = config;
  }

  async generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
  ): Promise<ModelResponse> {
    const { fullText, toolCalls } = await this.fetchResponse(conversation, tools);
    const chunks = chunkText(fullText, 30, 80);

    const response: ModelResponse = {
      fullText,
      chunks: streamFromChunks(chunks.length ? chunks : [fullText], this.config.partialDelayMs),
    };

    if (toolCalls.length) {
      response.toolCalls = toolCalls;
    }

    return response;
  }

  private buildMessages(conversation: ConversationTurn[]): AnthropicRequestMessage[] {
    const messages: AnthropicRequestMessage[] = [];

    for (const turn of conversation) {
      if (turn.role === "system") {
        continue;
      }

      if (turn.role === "tool") {
        const toolUseId = asNonEmptyString(turn.tool_use_id);
        const content =
          typeof turn.content === "string" ? turn.content : JSON.stringify(turn.content);
        if (!toolUseId) {
          messages.push({ role: "user", content });
          continue;
        }

        messages.push({
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: toolUseId,
              content,
            },
          ],
        });
        continue;
      }

      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        messages.push({
          role: "assistant",
          content: turn.content.map((toolCall) => ({
            type: "tool_use",
            id: toolCall.id,
            name: toolCall.name,
            input: toolCall.input,
          })),
        });
        continue;
      }

      if ((turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string") {
        messages.push({
          role: turn.role,
          content: turn.content,
        });
      }
    }

    return messages;
  }

  private async fetchResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
  ): Promise<FetchResult> {
    const messages = this.buildMessages(conversation);
    const toolList = (tools ?? []).filter((tool) => Boolean(tool.name));
    const withTools = toolList.length > 0;
    const maxTokens = withTools
      ? Math.min(this.config.maxTokens * 4, 4096)
      : this.config.maxTokens;

    // Anthropic tool names must match ^[a-zA-Z0-9_-]+$ — dots are not allowed.
    // Build a safe-name → original-name map so we can reverse after parsing.
    const toolNameToOriginal = new Map<string, string>();
    const safeTools = toolList.map((tool) => {
      const safeName = tool.name.replace(/\./g, "_");
      if (safeName !== tool.name) {
        toolNameToOriginal.set(safeName, tool.name);
      }
      return { ...tool, name: safeName };
    });

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.config.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: this.config.model,
        max_tokens: maxTokens,
        system: [
          "You are the Abyss voice-first coding assistant.",
          "Keep spoken responses concise, practical, and voice-friendly.",
          "Do not ask for speech-to-text tools. The user triggers listening manually.",
          "Avoid markdown tables and avoid long formatting.",
          "When the user asks you to work on code, create a PR, analyze a repository, or run any coding task, use the agent_spawn tool.",
          "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
          "Before calling agent_spawn, if you do not know the exact owner/repo string, always call repositories_list first to get the list of available repositories, then pick the one that best matches what the user said.",
          "Never guess or hallucinate a repository name — only use repos returned by repositories_list.",
        ].join(" "),
        ...(withTools ? { tools: safeTools } : {}),
        messages,
      }),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`anthropic_http_${response.status}:${bodyText.slice(0, 120)}`);
    }

    const body = (await response.json()) as AnthropicMessageResponse;
    const textParts: string[] = [];
    const toolCalls: ToolCallRequest[] = [];
    const content = Array.isArray(body.content) ? body.content : [];

    for (const block of content) {
      if (!isObject(block)) {
        continue;
      }

      const type = block.type;
      if (type === "text" && typeof block.text === "string") {
        const trimmed = block.text.trim();
        if (trimmed) {
          textParts.push(trimmed);
        }
        continue;
      }

      if (type === "tool_use") {
        const id = asNonEmptyString(block.id);
        const safeName = asNonEmptyString(block.name);
        const input = isObject(block.input) ? block.input : {};
        if (id && safeName) {
          // Restore the original dotted name (e.g. agent_spawn → agent.spawn)
          const originalName = toolNameToOriginal.get(safeName) ?? safeName;
          toolCalls.push({ id, name: originalName, input });
        }
      }
    }

    const text = textParts.join("\n").trim();
    if (!text && toolCalls.length > 0) {
      return { fullText: "", toolCalls };
    }

    if (!text) {
      return {
        fullText: "I heard you. I can continue once the model returns a full response.",
        toolCalls,
      };
    }

    return { fullText: text, toolCalls };
  }
}

import {
  BedrockRuntimeClient,
  ConverseCommand,
  ContentBlock,
  Message,
  SystemContentBlock,
  Tool,
  ToolConfiguration,
  ToolResultBlock,
  ToolResultContentBlock,
} from "@aws-sdk/client-bedrock-runtime";

import {
  ConversationTurn,
  ModelProvider,
  ModelResponse,
  ToolCallRequest,
  ToolDefinition,
} from "../core/types.js";
import { chunkText, streamFromChunks } from "./chunking.js";

export interface BedrockConfig {
  modelId: string;
  region: string;
  maxTokens: number;
  partialDelayMs: number;
}

interface FetchResult {
  fullText: string;
  toolCalls: ToolCallRequest[];
}

type BedrockConversationRole = "user" | "assistant";

interface BedrockClientLike {
  send(command: ConverseCommand): Promise<{
    output?: {
      message?: {
        content?: Array<{
          text?: string;
          toolUse?: {
            toolUseId?: string;
            name?: string;
            input?: Record<string, unknown>;
          };
        }>;
      };
    };
  }>;
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? value : null;
}

function tryParseJSONObject(value: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // Ignore invalid JSON and fall back to plain text tool results.
  }
  return null;
}

export class BedrockNovaProvider implements ModelProvider {
  readonly name = "bedrock";

  private readonly config: BedrockConfig;
  private readonly client: BedrockClientLike;

  constructor(config: BedrockConfig, client?: BedrockClientLike) {
    this.config = config;
    this.client = client ?? new BedrockRuntimeClient({ region: config.region });
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

    if (toolCalls.length > 0) {
      response.toolCalls = toolCalls;
    }

    return response;
  }

  private buildSystemPrompt(): SystemContentBlock[] {
    return [{
      text: [
        "You are the Abyss voice-first coding assistant.",
        "Keep spoken responses concise, practical, and voice-friendly.",
        "Do not ask for speech-to-text tools. The user triggers listening manually.",
        "Avoid markdown tables and avoid long formatting.",
        "If webqa.cursor.run is available and the user asks to validate behavior in a browser, call webqa.cursor.run.",
        "If cursor.agent.spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor.agent.spawn.",
        "When using cursor.agent.spawn or webqa.cursor.run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
        "If cursor.agent.spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent.spawn.",
        "When using legacy agent.spawn for repo work, if you do not know the exact owner/repo string, call repositories.list first.",
        "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
        "Never guess or hallucinate a repository name. Only use repos returned by repositories.list.",
        "If gmail.inbox, gmail.search, gmail.read, gmail.send, or gmail.reply tools are available, use them when the user asks about email.",
        "For gmail.search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
        "CRITICAL: Before calling gmail.send or gmail.reply, you MUST present the full draft (To, Subject, Body) to the user and wait for explicit confirmation. Never send or reply without the user saying yes.",
        "If Gmail tools are not available, tell the user to connect their Gmail account in the Settings screen.",
      ].join(" "),
    }];
  }

  private buildMessages(conversation: ConversationTurn[]): Message[] {
    const resolvedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "tool" && turn.tool_use_id) {
        resolvedToolUseIds.add(turn.tool_use_id);
      }
    }

    const skippedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        for (const toolCall of turn.content) {
          if (!resolvedToolUseIds.has(toolCall.id)) {
            skippedToolUseIds.add(toolCall.id);
          }
        }
      }
    }

    const messages: Message[] = [];
    let pendingToolResults: ToolResultBlock[] = [];

    const flushToolResults = () => {
      if (pendingToolResults.length === 0) {
        return;
      }
      messages.push({
        role: "user",
        content: pendingToolResults.map((toolResult) => ({ toolResult } as ContentBlock)),
      });
      pendingToolResults = [];
    };

    for (const turn of conversation) {
      if (turn.role === "system") {
        continue;
      }

      if (turn.role === "tool") {
        const toolUseId = asNonEmptyString(turn.tool_use_id);
        const textContent = typeof turn.content === "string"
          ? turn.content
          : JSON.stringify(turn.content);

        if (!toolUseId) {
          flushToolResults();
          messages.push({
            role: "user",
            content: [{ text: textContent }],
          });
          continue;
        }

        if (skippedToolUseIds.has(toolUseId)) {
          continue;
        }

        const jsonResult = tryParseJSONObject(textContent);
        pendingToolResults.push({
          toolUseId,
          status: textContent.startsWith("Error:") ? "error" : "success",
          content: jsonResult
            ? [{ json: jsonResult } as ToolResultContentBlock]
            : [{ text: textContent } as ToolResultContentBlock],
        });
        continue;
      }

      flushToolResults();

      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        const resolved = turn.content.filter((toolCall) => !skippedToolUseIds.has(toolCall.id));
        if (resolved.length === 0) {
          continue;
        }

        messages.push({
          role: "assistant",
          content: resolved.map((toolCall) => ({
            toolUse: {
              toolUseId: toolCall.id,
              name: toolCall.name.replace(/\./g, "_"),
              input: toolCall.input,
            },
          } as ContentBlock)),
        });
        continue;
      }

      if ((turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string") {
        messages.push({
          role: turn.role as BedrockConversationRole,
          content: [{ text: turn.content }],
        });
      }
    }

    flushToolResults();

    while (messages.length > 0 && messages[0]?.role !== "user") {
      messages.shift();
    }

    return messages;
  }

  private buildTools(tools?: ToolDefinition[]): {
    toolConfig?: ToolConfiguration;
    toolNameToOriginal: Map<string, string>;
  } {
    const toolNameToOriginal = new Map<string, string>();
    const toolSpecs: Tool[] = (tools ?? [])
      .filter((tool) => Boolean(tool.name))
      .map((tool) => {
        const safeName = tool.name.replace(/\./g, "_");
        if (safeName !== tool.name) {
          toolNameToOriginal.set(safeName, tool.name);
        }
        return {
          toolSpec: {
            name: safeName,
            description: tool.description,
            inputSchema: {
              json: tool.input_schema as Record<string, unknown>,
            },
          },
        } as Tool;
      });

    return {
      toolConfig: toolSpecs.length > 0 ? { tools: toolSpecs } : undefined,
      toolNameToOriginal,
    };
  }

  private async fetchResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
  ): Promise<FetchResult> {
    const messages = this.buildMessages(conversation);
    const { toolConfig, toolNameToOriginal } = this.buildTools(tools);

    const response = await this.client.send(new ConverseCommand({
      modelId: this.config.modelId,
      system: this.buildSystemPrompt(),
      messages,
      inferenceConfig: {
        maxTokens: toolConfig ? Math.min(this.config.maxTokens * 4, 8192) : this.config.maxTokens,
        temperature: 0.3,
      },
      ...(toolConfig ? { toolConfig } : {}),
    }));

    const contentBlocks = response.output?.message?.content ?? [];
    const textParts: string[] = [];
    const toolCalls: ToolCallRequest[] = [];

    for (const block of contentBlocks) {
      if (typeof block.text === "string") {
        textParts.push(block.text);
      }

      const toolUseId = asNonEmptyString(block.toolUse?.toolUseId);
      const toolName = asNonEmptyString(block.toolUse?.name);
      const toolInput = block.toolUse?.input;
      if (toolUseId && toolName && toolInput && typeof toolInput === "object" && !Array.isArray(toolInput)) {
        toolCalls.push({
          id: toolUseId,
          name: toolNameToOriginal.get(toolName) ?? toolName,
          input: toolInput as Record<string, unknown>,
        });
      }
    }

    return {
      fullText: textParts.join("").trim(),
      toolCalls,
    };
  }
}

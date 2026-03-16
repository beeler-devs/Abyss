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

interface ResponseContentBlock {
  text?: string;
  toolUse?: {
    toolUseId?: string;
    name?: string;
    input?: Record<string, unknown>;
  };
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

  private readonly bearerToken: string | undefined;

  constructor(config: BedrockConfig, client?: BedrockClientLike) {
    this.config = config;
    this.bearerToken = process.env.AWS_BEARER_TOKEN_BEDROCK || undefined;
    this.client = client ?? new BedrockRuntimeClient({ region: config.region });
  }

  async generateResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
  ): Promise<ModelResponse> {
    const { fullText, toolCalls } = await this.fetchResponse(conversation, tools, userPreferences, canvasCourseContext);
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

  private buildSystemPrompt(userPreferences?: Record<string, string>, canvasCourseContext?: string): SystemContentBlock[] {
    const parts: string[] = [
      "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
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
      "If github.repos.list, github.pr.list, github.pr.get, github.pr.reviews, github.actions.status, github.issues.list, github.pr.create, github.pr.merge, or github.issues.create are available, use them when the user asks about GitHub repositories, pull requests, CI, or issues.",
      "If you do not know the exact owner/repo string for a GitHub request, call github.repos.list first instead of guessing.",
      "CRITICAL: Before calling github.pr.create, github.pr.merge, or github.issues.create, you MUST present the intended action to the user and wait for explicit confirmation.",
      "If gmail.inbox, gmail.search, gmail.read, gmail.send, or gmail.reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
      "For gmail.search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
      "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail.send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
      "Similarly for gmail.reply — draft the reply body and call gmail.reply immediately. The app handles confirmation via a card.",
      "If gmail tools are NOT available but gmail.authenticate IS available, call gmail.authenticate when the user asks about email — this opens the sign-in screen on their device.",
      "If calendar.list, calendar.get, calendar.create, calendar.update, or calendar.delete tools are available, use them when the user asks about their schedule, meetings, or calendar.",
      "For calendar.list, translate natural language time references into ISO 8601 timeMin/timeMax (e.g. 'today' means start/end of today, 'this week' means Monday through Sunday, 'tomorrow at 3pm' needs the user's context).",
      "When the user asks to create, move, or schedule a calendar event, compose the details and call calendar.create or calendar.update immediately. The app will show a confirmation card.",
      "For calendar.delete, call the tool with the eventId. The app handles confirmation.",
      "Use preferences.set when the user asks you to remember something about themselves or their preferences. Common keys: user.name, user.timezone, communication.style, communication.verbosity, email.style, email.signoff. Use custom.<key> for anything else.",
      "If canvas.courses, canvas.assignments, canvas.todo, canvas.upcoming, canvas.grades, or canvas.announcements tools are available, use them when the user asks about their classes, coursework, assignments, grades, or academic schedule. These tools are available because the user has connected their Canvas LMS account.",
      "When the user asks about their classes or courses, call canvas.courses first to discover course IDs, then use those IDs for canvas.assignments, canvas.grades, or canvas.announcements.",
      "If canvas tools are NOT available but canvas.authenticate IS available, call canvas.authenticate when the user asks about coursework — this opens the settings screen on their device.",
      "You have cross-session memory. When you see a message starting with '[Prior context from previous sessions]', that is a summary of earlier conversations with this user. Use it naturally — reference prior topics, remember what the user told you, and build on previous discussions. Never say you don't have memory of past conversations.",
    ];

    if (userPreferences && Object.keys(userPreferences).length > 0) {
      const prefLines = Object.entries(userPreferences).map(([k, v]) => `- ${k}: ${v}`);
      parts.push(`User preferences (apply throughout):\n${prefLines.join("\n")}`);
    }

    if (canvasCourseContext) {
      parts.push(canvasCourseContext);
    }

    return [{ text: parts.join(" ") }];
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
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
  ): Promise<FetchResult> {
    const messages = this.buildMessages(conversation);
    const { toolConfig, toolNameToOriginal } = this.buildTools(tools);

    const maxTokens = toolConfig ? Math.min(this.config.maxTokens * 4, 8192) : this.config.maxTokens;

    const systemPrompt = this.buildSystemPrompt(userPreferences, canvasCourseContext);
    const contentBlocks: ResponseContentBlock[] = this.bearerToken
      ? await this.fetchWithBearer(messages, toolConfig, maxTokens, systemPrompt)
      : await this.fetchWithSdk(messages, toolConfig, maxTokens, systemPrompt);

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

  private async fetchWithSdk(
    messages: Message[],
    toolConfig: ToolConfiguration | undefined,
    maxTokens: number,
    systemPrompt: SystemContentBlock[],
  ): Promise<ResponseContentBlock[]> {
    const response = await this.client.send(new ConverseCommand({
      modelId: this.config.modelId,
      system: systemPrompt,
      messages,
      inferenceConfig: { maxTokens, temperature: 0.3 },
      ...(toolConfig ? { toolConfig } : {}),
    }));
    return (response.output?.message?.content ?? []) as ResponseContentBlock[];
  }

  private async fetchWithBearer(
    messages: Message[],
    toolConfig: ToolConfiguration | undefined,
    maxTokens: number,
    systemPrompt: SystemContentBlock[],
  ): Promise<ResponseContentBlock[]> {
    const url = `https://bedrock-runtime.${this.config.region}.amazonaws.com/model/${encodeURIComponent(this.config.modelId)}/converse`;

    const body: Record<string, unknown> = {
      system: systemPrompt.map((b) => ({ text: b.text })),
      messages: messages.map((m) => ({
        role: m.role,
        content: m.content?.map((c) => {
          if ("text" in c && c.text) return { text: c.text };
          if ("toolUse" in c && c.toolUse) return { toolUse: c.toolUse };
          if ("toolResult" in c && c.toolResult) return { toolResult: c.toolResult };
          return c;
        }),
      })),
      inferenceConfig: { maxTokens, temperature: 0.3 },
    };
    if (toolConfig) {
      body.toolConfig = toolConfig;
    }

    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.bearerToken}`,
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      const errorText = await res.text();
      throw new Error(`Bedrock API error ${res.status}: ${errorText}`);
    }

    const json = (await res.json()) as Record<string, unknown>;
    const output = json.output as Record<string, unknown> | undefined;
    const message = output?.message as Record<string, unknown> | undefined;
    return (message?.content ?? []) as ResponseContentBlock[];
  }
}

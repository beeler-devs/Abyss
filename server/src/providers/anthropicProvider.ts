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
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
  ): Promise<ModelResponse> {
    const { fullText, toolCalls } = await this.fetchResponse(conversation, tools, userPreferences, canvasCourseContext);
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
    // Collect all resolved tool_use IDs from tool result turns.
    const resolvedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "tool" && turn.tool_use_id) {
        resolvedToolUseIds.add(turn.tool_use_id);
      }
    }

    // Identify individual tool_use IDs that are orphaned (no matching tool result).
    // We skip only the specific unresolved IDs, not the entire assistant turn,
    // so that resolved tool calls within the same turn are preserved.
    const skippedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        for (const tc of turn.content) {
          if (!resolvedToolUseIds.has(tc.id)) {
            skippedToolUseIds.add(tc.id);
          }
        }
      }
    }

    const messages: AnthropicRequestMessage[] = [];
    // Pending tool_result blocks to be batched into a single user message (Anthropic requires
    // all tool results for a given assistant turn to be in one user message).
    let pendingToolResults: AnthropicToolResultRequestBlock[] = [];

    const flushToolResults = () => {
      if (pendingToolResults.length > 0) {
        messages.push({ role: "user", content: pendingToolResults });
        pendingToolResults = [];
      }
    };

    for (const turn of conversation) {
      if (turn.role === "system") {
        continue;
      }

      if (turn.role === "tool") {
        const toolUseId = asNonEmptyString(turn.tool_use_id);
        const content =
          typeof turn.content === "string" ? turn.content : JSON.stringify(turn.content);

        if (!toolUseId) {
          flushToolResults();
          messages.push({ role: "user", content });
          continue;
        }

        // Skip tool results that belong to an orphaned (skipped) assistant turn.
        if (skippedToolUseIds.has(toolUseId)) {
          continue;
        }

        pendingToolResults.push({ type: "tool_result", tool_use_id: toolUseId, content });
        continue;
      }

      flushToolResults();

      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        // Filter out only the specific orphaned tool calls (those without a result).
        const resolved = turn.content.filter((tc) => !skippedToolUseIds.has(tc.id));
        if (resolved.length === 0) {
          continue;
        }
        messages.push({
          role: "assistant",
          content: resolved.map((toolCall) => ({
            type: "tool_use",
            id: toolCall.id,
            name: toolCall.name,
            input: toolCall.input,
          })),
        });
        continue;
      }

      if ((turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string") {
        messages.push({ role: turn.role, content: turn.content });
      }
    }

    flushToolResults();

    // Anthropic requires the first message to be from the user.
    while (messages.length > 0 && messages[0].role !== "user") {
      messages.shift();
    }

    return messages;
  }

  private buildSystemPrompt(userPreferences?: Record<string, string>, canvasCourseContext?: string): string {
    const parts: string[] = [
      "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
      "Keep spoken responses concise, practical, and voice-friendly.",
      "Do not ask for speech-to-text tools. The user triggers listening manually.",
      "Avoid markdown tables and avoid long formatting.",
      "If webqa_cursor_run is available and the user asks to validate behavior in a browser, call webqa_cursor_run.",
      "If cursor_agent_spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor_agent_spawn.",
      "When using cursor_agent_spawn or webqa_cursor_run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
      "If cursor_agent_spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent_spawn.",
      "When using legacy agent_spawn for repo work, if you do not know the exact owner/repo string, call repositories_list first.",
      "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
      "Never guess or hallucinate a repository name — only use repos returned by repositories_list.",
      "If gmail_inbox, gmail_search, gmail_read, gmail_send, or gmail_reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
      "For gmail_search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
      "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail_send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
      "Similarly for gmail_reply — draft the reply body and call gmail_reply immediately. The app handles confirmation via a card.",
      "If gmail tools are NOT available but gmail_authenticate IS available, call gmail_authenticate when the user asks about email — this opens the sign-in screen on their device.",
      "If calendar_list, calendar_get, calendar_create, calendar_update, or calendar_delete tools are available, use them when the user asks about their schedule, meetings, or calendar.",
      "For calendar_list, translate natural language time references into ISO 8601 timeMin/timeMax (e.g. 'today' means start/end of today, 'this week' means Monday through Sunday, 'tomorrow at 3pm' needs the user's context).",
      "When the user asks to create, move, or schedule a calendar event, compose the details and call calendar_create or calendar_update immediately. The app will show a confirmation card.",
      "For calendar_delete, call the tool with the eventId. The app handles confirmation.",
      "Use preferences_set when the user asks you to remember something about themselves or their preferences. Common keys: user.name, user.timezone, communication.style, communication.verbosity, email.style, email.signoff. Use custom.<key> for anything else.",
      "If canvas_courses, canvas_assignments, canvas_todo, canvas_upcoming, canvas_grades, or canvas_announcements tools are available, use them when the user asks about their classes, coursework, assignments, grades, or academic schedule. These tools are available because the user has connected their Canvas LMS account.",
      "When the user asks about their classes or courses, call canvas_courses first to discover course IDs, then use those IDs for canvas_assignments, canvas_grades, or canvas_announcements.",
      "If canvas tools are NOT available but canvas_authenticate IS available, call canvas_authenticate when the user asks about coursework — this opens the settings screen on their device.",
      "Never use cursor_agent_spawn or agent_spawn for email, calendar, or Canvas tasks. These are handled exclusively by their dedicated tools (gmail_*, calendar_*, canvas_*).",
    ];

    if (userPreferences && Object.keys(userPreferences).length > 0) {
      const prefLines = Object.entries(userPreferences).map(([k, v]) => `- ${k}: ${v}`);
      parts.push(`User preferences (apply throughout):\n${prefLines.join("\n")}`);
    }

    if (canvasCourseContext) {
      parts.push(canvasCourseContext);
    }

    return parts.join(" ");
  }

  private async fetchResponse(
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
  ): Promise<FetchResult> {
    const messages = this.buildMessages(conversation);
    const toolList = (tools ?? []).filter((tool) => Boolean(tool.name));
    const withTools = toolList.length > 0;
    // Tool-using turns need more tokens for structured JSON output.
    // Scale up by 4x but cap at 8192 to stay within reasonable bounds.
    const maxTokens = withTools
      ? Math.min(this.config.maxTokens * 4, 8192)
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
        system: this.buildSystemPrompt(userPreferences, canvasCourseContext),
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
        fullText: "I heard you, but the model returned an empty response. Could you try again?",
        toolCalls,
      };
    }

    return { fullText: text, toolCalls };
  }
}

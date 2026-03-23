import {
  ConversationTurn,
  ModelProvider,
  ModelResponse,
  ToolCallRequest,
  ToolDefinition,
} from "../core/types.js";

export interface ClaudeConfig {
  apiKey: string;
  model: string;
  proModel?: string;
  maxTokens: number;
}

type AnthropicRequestRole = "user" | "assistant";

interface AnthropicTextBlock {
  type: "text";
  text: string;
}

interface AnthropicToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

interface AnthropicToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string;
}

type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock;

interface AnthropicRequestMessage {
  role: AnthropicRequestRole;
  content: string | AnthropicContentBlock[];
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return value.trim().length ? value : null;
}

export class ClaudeProvider implements ModelProvider {
  readonly name = "claude";
  private readonly config: ClaudeConfig;

  constructor(config: ClaudeConfig) {
    this.config = config;
  }

  async generateResponse(
    _conversation: ConversationTurn[],
    _tools?: ToolDefinition[],
    _userPreferences?: Record<string, string>,
    _canvasCourseContext?: string,
    _modelOverride?: string,
    _systemPrompt?: string,
  ): Promise<ModelResponse> {
    // Stub — implemented in Task 3/4
    throw new Error("Not implemented");
  }

  /** Exposed for testing. */
  prepareTools(tools: ToolDefinition[]): {
    safeTools: ToolDefinition[];
    toolNameToOriginal: Map<string, string>;
  } {
    const toolNameToOriginal = new Map<string, string>();
    const safeTools = tools
      .filter((t) => Boolean(t.name))
      .map((tool) => {
        const safeName = tool.name.replace(/\./g, "_");
        if (safeName !== tool.name) {
          toolNameToOriginal.set(safeName, tool.name);
        }
        return { ...tool, name: safeName };
      });
    return { safeTools, toolNameToOriginal };
  }

  /** Exposed for testing. */
  buildMessages(conversation: ConversationTurn[]): AnthropicRequestMessage[] {
    // Collect all resolved tool_use IDs from tool result turns.
    const resolvedToolUseIds = new Set<string>();
    for (const turn of conversation) {
      if (turn.role === "tool" && turn.tool_use_id) {
        resolvedToolUseIds.add(turn.tool_use_id);
      }
    }

    // Identify orphaned tool_use IDs (no matching tool result).
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
    let pendingToolResults: AnthropicToolResultBlock[] = [];

    const flushToolResults = () => {
      if (pendingToolResults.length > 0) {
        messages.push({ role: "user", content: pendingToolResults });
        pendingToolResults = [];
      }
    };

    for (const turn of conversation) {
      if (turn.role === "system") continue;

      if (turn.role === "tool") {
        const toolUseId = asNonEmptyString(turn.tool_use_id);
        const content =
          typeof turn.content === "string" ? turn.content : JSON.stringify(turn.content);

        if (!toolUseId) {
          flushToolResults();
          messages.push({ role: "user", content });
          continue;
        }

        if (skippedToolUseIds.has(toolUseId)) continue;

        pendingToolResults.push({ type: "tool_result", tool_use_id: toolUseId, content });
        continue;
      }

      flushToolResults();

      if (turn.role === "assistant" && Array.isArray(turn.content)) {
        const resolved = turn.content.filter((tc) => !skippedToolUseIds.has(tc.id));
        if (resolved.length === 0) continue;
        messages.push({
          role: "assistant",
          content: resolved.map((tc) => ({
            type: "tool_use" as const,
            id: tc.id,
            name: tc.name,
            input: tc.input,
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
}

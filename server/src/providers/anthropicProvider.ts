import { ConversationTurn, GenerateOptions, ModelProvider, ModelResponse } from "../core/types.js";
import { listOrganizations, listRepositories } from "../tools/githubTools.js";
import { chunkText, streamFromChunks } from "./chunking.js";

export interface AnthropicConfig {
  apiKey: string;
  model: string;
  maxTokens: number;
  partialDelayMs: number;
}

// ---------------------------------------------------------------------------
// Anthropic API wire types
// ---------------------------------------------------------------------------

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

type AnthropicContentBlock = AnthropicTextBlock | AnthropicToolUseBlock;

interface AnthropicMessageResponse {
  content?: AnthropicContentBlock[];
  stop_reason?: string;
}

interface AnthropicToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string;
}

// ---------------------------------------------------------------------------
// GitHub tool schemas exposed to Claude
// ---------------------------------------------------------------------------

const GITHUB_TOOLS = [
  {
    name: "github__listOrganizations",
    description:
      "List all GitHub organizations the authenticated user belongs to. Call this when the user asks about their GitHub orgs, organizations, or companies.",
    input_schema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "github__listRepositories",
    description:
      "List GitHub repositories for the authenticated user or a specific organization. " +
      "When no org is specified, returns repos the user owns, collaborates on, or has access to. " +
      "When org is specified, returns repos for that organization.",
    input_schema: {
      type: "object",
      properties: {
        org: {
          type: "string",
          description: "Optional GitHub organization login (e.g. 'my-company'). Omit to list the user's own repos.",
        },
      },
      required: [],
    },
  },
] as const;

// ---------------------------------------------------------------------------
// Provider implementation
// ---------------------------------------------------------------------------

export class AnthropicProvider implements ModelProvider {
  readonly name = "anthropic";

  private readonly config: AnthropicConfig;

  constructor(config: AnthropicConfig) {
    this.config = config;
  }

  async generateResponse(
    conversation: ConversationTurn[],
    options?: GenerateOptions,
  ): Promise<ModelResponse> {
    const fullText = await this.runAgentLoop(conversation, options?.githubToken);
    const chunks = chunkText(fullText, 30, 80);

    return {
      fullText,
      chunks: streamFromChunks(chunks.length ? chunks : [fullText], this.config.partialDelayMs),
    };
  }

  /**
   * Agentic loop: calls Claude, handles tool_use stop reason by executing
   * the appropriate GitHub tool, then continues until Claude returns end_turn.
   */
  private async runAgentLoop(
    conversation: ConversationTurn[],
    githubToken: string | undefined,
  ): Promise<string> {
    const hasGithubToken = typeof githubToken === "string" && githubToken.length > 0;

    const messages: Array<{
      role: "user" | "assistant";
      content: string | AnthropicContentBlock[] | AnthropicToolResultBlock[];
    }> = conversation
      .filter((t) => t.role !== "system")
      .map((t) => ({ role: t.role as "user" | "assistant", content: t.content }));

    // Only expose GitHub tools when the user has authorized GitHub.
    const tools = hasGithubToken ? GITHUB_TOOLS : [];

    const maxToolTurns = 5;
    let toolTurns = 0;

    while (toolTurns <= maxToolTurns) {
      const response = await this.callAPI(messages, tools);

      const content = response.content ?? [];
      const stopReason = response.stop_reason;

      // Append assistant message to the local conversation so Claude gets full context.
      messages.push({ role: "assistant", content });

      if (stopReason !== "tool_use") {
        // Final text response — extract and return.
        const text = content
          .filter((b): b is AnthropicTextBlock => b.type === "text")
          .map((b) => b.text.trim())
          .join("\n")
          .trim();

        return text || "I heard you. I can continue once the model returns a full response.";
      }

      // Handle tool_use blocks.
      const toolUseBlocks = content.filter(
        (b): b is AnthropicToolUseBlock => b.type === "tool_use",
      );

      if (toolUseBlocks.length === 0) {
        // Shouldn't happen but bail gracefully.
        break;
      }

      // Execute all tool calls and collect results.
      const toolResults: AnthropicToolResultBlock[] = await Promise.all(
        toolUseBlocks.map(async (block) => {
          const result = await this.executeGithubTool(block.name, block.input, githubToken!);
          return {
            type: "tool_result" as const,
            tool_use_id: block.id,
            content: result,
          };
        }),
      );

      // Append tool results as a user message (Anthropic convention).
      messages.push({ role: "user", content: toolResults });
      toolTurns++;
    }

    return "I ran into an issue fetching GitHub data. Please try again.";
  }

  private async executeGithubTool(
    toolName: string,
    input: Record<string, unknown>,
    token: string,
  ): Promise<string> {
    try {
      switch (toolName) {
        case "github__listOrganizations":
          return await listOrganizations(token);
        case "github__listRepositories": {
          const org = typeof input.org === "string" ? input.org : undefined;
          return await listRepositories(token, org);
        }
        default:
          return JSON.stringify({ error: `Unknown tool: ${toolName}` });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      return JSON.stringify({ error: message });
    }
  }

  private async callAPI(
    messages: Array<{
      role: "user" | "assistant";
      content: string | AnthropicContentBlock[] | AnthropicToolResultBlock[];
    }>,
    tools: ReadonlyArray<{ name: string; description: string; input_schema: object }>,
  ): Promise<AnthropicMessageResponse> {
    const body: Record<string, unknown> = {
      model: this.config.model,
      max_tokens: this.config.maxTokens,
      system: [
        "You are the Abyss voice-first coding assistant.",
        "Keep spoken responses concise, practical, and voice-friendly.",
        "Do not ask for speech-to-text tools. The user triggers listening manually.",
        "Avoid markdown tables and avoid long formatting.",
        "When the user asks about GitHub repositories or organizations, use the provided tools to fetch real data.",
      ].join(" "),
      messages,
    };

    if (tools.length > 0) {
      body.tools = tools;
    }

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.config.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`anthropic_http_${response.status}:${bodyText.slice(0, 120)}`);
    }

    return (await response.json()) as AnthropicMessageResponse;
  }
}

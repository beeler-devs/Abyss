import {
  ConversationTurn,
  ModelProvider,
  ModelResponse,
  ToolCallRequest,
  ToolDefinition,
} from "../core/types.js";

function chunkBufferedText(text: string, minChunk = 30, maxChunk = 80): string[] {
  if (!text.trim()) return [];
  const chunks: string[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const remaining = text.length - cursor;
    const target = Math.min(remaining, Math.floor(Math.random() * (maxChunk - minChunk + 1)) + minChunk);
    let end = cursor + target;
    if (end < text.length) {
      const breakpoint = text.lastIndexOf(" ", end);
      if (breakpoint > cursor + Math.floor(minChunk / 2)) {
        end = breakpoint;
      }
    }
    if (end <= cursor) end = cursor + target;
    const chunk = text.slice(cursor, end);
    if (chunk.length > 0) chunks.push(chunk);
    cursor = end;
  }
  return chunks;
}

async function* streamFromBuffer(chunks: string[]): AsyncIterable<string> {
  for (const chunk of chunks) {
    yield chunk;
  }
}

export interface ClaudeConfig {
  apiKey: string;
  model: string;
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
    conversation: ConversationTurn[],
    tools?: ToolDefinition[],
    userPreferences?: Record<string, string>,
    canvasCourseContext?: string,
    modelOverride?: string,
    systemPrompt?: string,
  ): Promise<ModelResponse> {
    const messages = this.buildMessages(conversation);
    const system = systemPrompt ?? this.buildSystemPrompt(userPreferences, canvasCourseContext);
    const toolList = tools ?? [];
    const { safeTools, toolNameToOriginal } = this.prepareTools(toolList);
    const withTools = safeTools.length > 0;
    const model = this.resolveModel(modelOverride);
    const maxTokens = this.resolveMaxTokens(withTools);

    const sseEvents = await this.fetchSSE(
      messages,
      system,
      model,
      maxTokens,
      withTools ? safeTools : undefined,
    );

    const { fullText, toolCalls } = this.parseSSEEvents(sseEvents, toolNameToOriginal);

    // Compute fallback before chunking so chunks and fullText stay consistent.
    const resolvedText = fullText || (toolCalls.length > 0 ? "" : "I heard you, but the model returned an empty response. Could you try again?");
    const textChunks = chunkBufferedText(resolvedText);

    const response: ModelResponse = {
      fullText: resolvedText,
      chunks: streamFromBuffer(textChunks),
    };

    if (toolCalls.length > 0) {
      response.toolCalls = toolCalls;
    }

    return response;
  }

  private buildSystemPrompt(userPreferences?: Record<string, string>, canvasCourseContext?: string): string {
    const parts: string[] = [
      "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
      "VOICE OUTPUT RULES (all responses are spoken aloud via TTS):",
      "Lead with the answer. Be concise and direct — no filler, no hedging.",
      "Never say URLs, links, or web addresses aloud. Say 'I found an article about X' instead.",
      "Never read code aloud. Summarize what the code does instead.",
      "Never say file paths aloud. Refer to files by purpose (e.g. 'the conductor service' not '/server/src/core/conductorService.ts').",
      "Never say JSON, structured data, UUIDs, commit hashes, or ARNs aloud. Refer to them contextually.",
      "Convert ISO timestamps to natural language ('tomorrow at 3' not '2026-03-17T15:00:00Z').",
      "Say people's names instead of email addresses unless disambiguation is needed.",
      "For lists longer than 3-4 items, state the top items and summarize the rest ('and 8 more').",
      "Summarize errors and stack traces to the root cause — never read them out.",
      "Do not narrate what the UI is already showing. If a card displays the details, keep the spoken response brief.",
      "Do not use markdown formatting (bold, headers, backticks, bullets) — it will be spoken literally.",
      "Do not ask for speech-to-text tools. The user triggers listening manually.",
      "If webqa_cursor_run is available and the user asks to validate behavior in a browser, call webqa_cursor_run.",
      "If cursor_agent_spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor_agent_spawn.",
      "When using cursor_agent_spawn or webqa_cursor_run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
      "After spawning a Cursor Cloud Agent, keep your spoken response brief — just confirm what you started. The UI already shows an agent progress card with status, branch name, and a link to the agent run. Do not mention URLs, links, or agent run details in your response.",
      "If cursor_agent_spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent_spawn.",
      "When using legacy agent_spawn for repo work, if you do not know the exact owner/repo string, call repositories_list first.",
      "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
      "Never guess or hallucinate a repository name — only use repos returned by repositories_list.",
      "If github_repos_list, github_pr_list, github_pr_get, github_pr_reviews, github_actions_status, github_issues_list, github_pr_create, github_pr_merge, or github_issues_create tools are available, use them when the user asks about GitHub repositories, pull requests, CI, or issues.",
      "If you do not know the exact owner/repo string for a GitHub request, call github_repos_list first instead of guessing.",
      "CRITICAL: Before calling github_pr_create, github_pr_merge, or github_issues_create, you MUST present the intended action to the user and wait for explicit confirmation.",
      "If gmail_inbox, gmail_search, gmail_read, gmail_send, or gmail_reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
      "For gmail_search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
      "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail_send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
      "Similarly for gmail_reply — draft the reply body and call gmail_reply immediately. The app handles confirmation via a card.",
      "If gmail tools are NOT available but gmail_authenticate IS available, call gmail_authenticate when the user asks about email — this opens the sign-in screen on their device.",
      "If calendar_list, calendar_get, calendar_create, calendar_update, or calendar_delete tools are available, use them when the user asks about their schedule, meetings, or calendar.",
      "For calendar_list, translate natural language time references into ISO 8601 timeMin/timeMax (e.g. 'today' means start/end of today, 'this week' means Monday through Sunday, 'tomorrow at 3pm' needs the user's context).",
      "When the user asks to create, move, or schedule a calendar event, compose the details and call calendar_create or calendar_update immediately. The app will show a confirmation card.",
      "For calendar_delete, call the tool with the eventId. The app handles confirmation.",
      "Use preferences_set when the user asks you to remember something about themselves or their preferences. Common keys: user.name, user.timezone, communication.style, communication.verbosity, email.style, email.signoff, bridge.claude.allowedTools. Use custom.<key> for anything else.",
      "The preference bridge.claude.allowedTools controls which tools Claude Code can use on the paired Mac. Available tools: Bash (run shell commands), Read (read files), Edit (modify existing files), Write (create new files), LS (list directories), Glob (find files by name pattern), Grep (search file contents), MultiEdit (batch file edits). If the user wants to change these permissions, call preferences_set('bridge.claude.allowedTools', 'Tool1,Tool2,...').",
      "If canvas_courses, canvas_assignments, canvas_todo, canvas_upcoming, canvas_grades, or canvas_announcements tools are available, use them when the user asks about their classes, coursework, assignments, grades, or academic schedule. These tools are available because the user has connected their Canvas LMS account.",
      "When the user asks about their classes or courses, call canvas_courses first to discover course IDs, then use those IDs for canvas_assignments, canvas_grades, or canvas_announcements.",
      "For canvas_assignments, always provide afterDate (default to current ISO timestamp) to exclude past assignments. When the user asks generally about assignments, set beforeDate to ~2 weeks from now. Only omit date filters when the user explicitly asks for all or past assignments. For canvas_announcements, set afterDate to ~2 weeks ago by default to show only recent announcements.",
      "If canvas tools are NOT available but canvas_authenticate IS available, call canvas_authenticate when the user asks about coursework — this opens the settings screen on their device.",
      "Never use cursor_agent_spawn or agent_spawn for email, calendar, or Canvas tasks. These are handled exclusively by their dedicated tools (gmail_*, calendar_*, canvas_*).",
      "Never call gmail_authenticate or canvas_authenticate more than once per conversation turn. If the tool returns that the user needs to authenticate, tell the user and stop — do not retry.",
      "If bridge_nova_start, bridge_nova_act, and bridge_nova_stop tools are available, use them when the user asks to browse the web, open a website, interact with a web page, automate browser tasks, or mentions 'Nova Act'. These tools control a real Chrome browser on the user's paired Mac via natural-language instructions. Flow: 1) call bridge_nova_start with the URL to open, 2) call bridge_nova_act with step-by-step instructions (e.g. 'Click Sign In', 'Type hello in the search box', 'Scroll down'), 3) call bridge_nova_stop when done. Each bridge_nova_act call executes one instruction — chain multiple calls for multi-step workflows. You CAN open any website including Figma, Google Docs, social media, etc.",
      "If bridge_exec_run or bridge_exec_start tools are available, use them when the user asks to run shell commands, check files, or perform terminal operations on their paired Mac. IMPORTANT: Extract only the raw shell command from the user's request — never include conversational phrases like 'on mac', 'on the bridge', 'on my computer' in the command argument. Example: 'run ls -la on mac' → command is 'ls -la'. If bridge_claude_run is available, use it for complex coding/editing tasks on the Mac.",
      "You have cross-session memory. When you see a message starting with '[Prior context from previous sessions]', that is a summary of earlier conversations with this user. Use it naturally — reference prior topics, remember what the user told you, and build on previous discussions. Never say you don't have memory of past conversations.",
      "INLINE CARD RENDERING: When tool results contain cardId fields or card reference instructions, you MUST reference each card inline in your response using fenced code block syntax: ```card:TYPE:CARD_ID\\n``` on its own line, where TYPE is email/calendar/canvas/agent/bridge/draft and CARD_ID is the exact UUID from the tool result. Place cards at the natural point in your narrative where they are contextually relevant. NEVER describe card data in prose when a card reference exists — the card already shows it. Every cardId from a tool result MUST appear exactly once as a card reference. Multiple cards can appear in sequence or separated by prose.",
    ];

    if (userPreferences && Object.keys(userPreferences).length > 0) {
      const prefLines = Object.entries(userPreferences).map(([k, v]) => `- ${k}: ${v}`);
      parts.push(`User preferences (apply throughout):\n${prefLines.join("\n")}`);
    }

    if (canvasCourseContext) {
      parts.push(canvasCourseContext);
    }

    return parts.join("\n\n");
  }

  private async fetchSSE(
    messages: AnthropicRequestMessage[],
    system: string,
    model: string,
    maxTokens: number,
    tools?: ToolDefinition[],
  ): Promise<Array<Record<string, any>>> {
    const body: Record<string, unknown> = {
      model,
      max_tokens: maxTokens,
      temperature: 0.3,
      system,
      messages,
      stream: true,
    };

    if (tools && tools.length > 0) {
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
      signal: AbortSignal.timeout(120_000),
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`anthropic_http_${response.status}:${bodyText.slice(0, 500)}`);
    }

    if (!response.body) {
      throw new Error("anthropic_no_body: Response has no body");
    }

    // Parse SSE stream
    const events: Array<Record<string, any>> = [];
    const decoder = new TextDecoder();
    let buffer = "";

    for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        if (line.startsWith("data: ")) {
          const data = line.slice(6).trim();
          if (data === "[DONE]") continue; // defensive: Anthropic doesn't emit [DONE] but guard against future changes
          try {
            events.push(JSON.parse(data));
          } catch {
            // Skip malformed SSE lines
          }
        }
      }
    }

    return events;
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
  resolveModel(modelOverride?: string): string {
    return modelOverride ?? this.config.model;
  }

  /** Exposed for testing. */
  resolveMaxTokens(withTools: boolean): number {
    if (!withTools) return this.config.maxTokens;
    return Math.min(this.config.maxTokens * 4, 16384);
  }

  /** Exposed for testing. Parses pre-parsed SSE event objects into text + tool calls. */
  parseSSEEvents(
    events: Array<Record<string, any>>,
    toolNameToOriginal: Map<string, string>,
  ): { fullText: string; toolCalls: ToolCallRequest[] } {
    const textParts: string[] = [];
    const toolCalls: ToolCallRequest[] = [];

    // Accumulators keyed by content block index
    const toolInputBuffers = new Map<number, string>();
    const toolMeta = new Map<number, { id: string; name: string }>();

    for (const event of events) {
      if (event.type === "content_block_start") {
        const block = event.content_block;
        if (block?.type === "tool_use") {
          toolMeta.set(event.index, { id: block.id, name: block.name });
          toolInputBuffers.set(event.index, "");
        }
      } else if (event.type === "content_block_delta") {
        const delta = event.delta;
        if (delta?.type === "text_delta" && typeof delta.text === "string") {
          textParts.push(delta.text);
        } else if (delta?.type === "input_json_delta" && typeof delta.partial_json === "string") {
          const existing = toolInputBuffers.get(event.index) ?? "";
          toolInputBuffers.set(event.index, existing + delta.partial_json);
        }
      } else if (event.type === "content_block_stop") {
        const meta = toolMeta.get(event.index);
        if (meta) {
          const jsonStr = toolInputBuffers.get(event.index) ?? "{}";
          let input: Record<string, unknown> = {};
          try {
            input = JSON.parse(jsonStr);
          } catch {
            // Malformed tool input — use empty object
          }
          const originalName = toolNameToOriginal.get(meta.name) ?? meta.name;
          toolCalls.push({ id: meta.id, name: originalName, input });
          toolMeta.delete(event.index);
          toolInputBuffers.delete(event.index);
        }
      }
    }

    return { fullText: textParts.join("").trim(), toolCalls };
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
            name: tc.name.replace(/\./g, "_"),
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

import crypto from "node:crypto";

import { CursorClient } from "../integrations/cursorClient.js";
import {
  isTerminalAgentStatus,
  normalizeMode,
  normalizeStatus,
  ParsedCursorWebhookEvent,
  parseCursorAgentSnapshotFromResult,
  parseCursorWebhookPayload,
} from "../integrations/cursorPayload.js";
import { asString, makeDeterministicEventId, makeEvent } from "./events.js";
import { logger } from "./logger.js";
import { SessionStore } from "./sessionStore.js";
import {
  BridgeToolExecutor,
  CursorAgentMode,
  CursorAgentRunRecord,
  EventEnvelope,
  ModelProvider,
  ModelResponse,
  SessionState,
  ToolCallRequest,
  ToolDefinition,
} from "./types.js";

export interface ConductorServiceConfig {
  maxTurns: number;
  rateLimitPerMinute: number;
}

export interface ConductorServiceDependencies {
  cursorClient?: CursorClient;
  webhookPendingTtlMs?: number;
  now?: () => Date;
  bridgeToolExecutor?: BridgeToolExecutor;
}

export interface CursorWebhookHandleResult {
  statusCode: number;
  payload: Record<string, unknown>;
}

const LEGACY_CLIENT_TOOLS: ToolDefinition[] = [
  {
    name: "agent.spawn",
    description:
      "Launch a new Cursor Cloud Agent to work on a repository. Use for coding tasks, PR creation, analysis. Requires a prompt and either repository (format: owner/repo) or prUrl.",
    input_schema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The task for the agent to perform" },
        repository: { type: "string", description: "GitHub repository in owner/repo format" },
        ref: { type: "string", description: "Git ref/branch to work from" },
        prUrl: { type: "string", description: "Existing PR URL to work on instead of a repo" },
        model: { type: "string", description: "Model to use (optional)" },
        autoCreatePr: {
          type: "boolean",
          description: "Whether to auto-create a PR. Default false for safety.",
        },
        autoBranch: {
          type: "boolean",
          description: "Whether to auto-create a branch. Default false for safety.",
        },
        skipReviewerRequest: { type: "boolean" },
        branchName: { type: "string" },
      },
      required: ["prompt"],
    },
  },
  {
    name: "agent.status",
    description: "Get the current status of a running Cursor Cloud Agent by its ID.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID returned from agent.spawn" },
      },
      required: ["id"],
    },
  },
  {
    name: "agent.cancel",
    description: "Stop a running Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID to cancel" },
      },
      required: ["id"],
    },
  },
  {
    name: "agent.followup",
    description: "Add a follow-up instruction to an existing Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID" },
        prompt: { type: "string", description: "Follow-up instruction" },
      },
      required: ["id", "prompt"],
    },
  },
  {
    name: "agent.list",
    description: "List Cursor Cloud Agents for the authenticated user.",
    input_schema: {
      type: "object",
      properties: {
        limit: { type: "number" },
        cursor: { type: "string" },
        prUrl: { type: "string" },
      },
    },
  },
  {
    name: "repositories.list",
    description:
      "List all GitHub repositories the user has connected to Cursor. Call this before agent.spawn when you do not know the exact owner/repo string, or when the user refers to a repo by name. Returns a list of {repository, owner, name} objects. Always prefer a repository from this list over guessing.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "repositories.select",
    description:
      "Present an interactive repository selection UI to the user. Use this when the user refers to a repository ambiguously, when you cannot confidently identify which repository they mean, or when multiple matches exist. The UI displays all connected repositories grouped by organization. Returns the user's selection. This tool blocks until the user makes a choice or cancels.",
    input_schema: {
      type: "object",
      properties: {
        prompt: {
          type: "string",
          description: "Optional message explaining what the selection is for, shown to the user",
        },
        filter: {
          type: "string",
          description: "Optional partial name to pre-filter the repository list",
        },
      },
    },
  },
];

const SERVER_CURSOR_TOOLS: ToolDefinition[] = [
  {
    name: "cursor.agent.spawn",
    description:
      "Spawn a Cursor Cloud Agent from the server with webhook tracking enabled. Prefer this over agent.spawn when available.",
    input_schema: {
      type: "object",
      properties: {
        prompt: { type: "string" },
        repoUrl: { type: "string" },
        ref: { type: "string" },
        metadata: { type: "object" },
        mode: { type: "string", description: "code | computer_use | webqa" },
      },
      required: ["prompt"],
    },
  },
  {
    name: "cursor.agent.status",
    description: "Query status for a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "cursor.agent.followup",
    description: "Send follow-up instructions to a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
        message: { type: "string" },
      },
      required: ["agentId", "message"],
    },
  },
  {
    name: "cursor.agent.cancel",
    description: "Cancel a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "webqa.cursor.run",
    description:
      "Run browser validation/computer-use QA in Cursor. Use this when the user asks to validate behavior in a browser.",
    input_schema: {
      type: "object",
      properties: {
        url: { type: "string" },
        flowSpec: { type: "object" },
        assertions: { type: "object" },
        budget: { type: "object" },
      },
      required: ["url", "flowSpec"],
    },
  },
  {
    name: "webqa.cursor.status",
    description: "Check status of a Cursor-based WebQA run.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "webqa.cursor.followup",
    description: "Send follow-up instructions to a Cursor WebQA run.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
        instruction: { type: "string" },
      },
      required: ["agentId", "instruction"],
    },
  },
];

const SERVER_BRIDGE_TOOLS: ToolDefinition[] = [
  {
    name: "bridge.exec.run",
    description:
      "Run a shell command on a paired Abyss Bridge Mac device. Use for local tests/build checks.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        command: { type: "string", description: "Shell command to execute (example: npm test)." },
        cwd: { type: "string", description: "Optional relative directory under workspace root." },
        timeoutSec: { type: "number", description: "Optional command timeout in seconds (max 600)." },
      },
      required: ["command"],
    },
  },
  {
    name: "bridge.fs.readFile",
    description:
      "Read a UTF-8 text file from a paired Abyss Bridge Mac device workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        path: { type: "string", description: "Relative file path under workspace root." },
      },
      required: ["path"],
    },
  },
];

const WEBHOOK_PENDING_TTL_MS = 10 * 60_000;

function waitForToolResult(
  session: SessionState,
  callId: string,
  timeoutMs: number,
): Promise<{ result: string | null; error: string | null }> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      session.toolResultResolvers.delete(callId);
      resolve({ result: null, error: "tool_result_timeout" });
    }, timeoutMs);

    session.toolResultResolvers.set(callId, (result, error) => {
      clearTimeout(timer);
      session.toolResultResolvers.delete(callId);
      resolve({ result, error });
    });
  });
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function stringFromRecord(record: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.length) {
        return trimmed;
      }
    }
  }
  return undefined;
}

export class ConductorService {
  private readonly provider: ModelProvider;
  private readonly sessions: SessionStore;
  private readonly cursorClient: CursorClient;
  private readonly webhookPendingTtlMs: number;
  private readonly now: () => Date;
  private readonly bridgeToolExecutor?: BridgeToolExecutor;
  private readonly conversationPollers = new Map<string, ReturnType<typeof setInterval>>();
  private static readonly CONVERSATION_POLL_INTERVAL_MS = 3_000;

  constructor(provider: ModelProvider, config: ConductorServiceConfig, dependencies: ConductorServiceDependencies = {}) {
    this.provider = provider;
    this.sessions = new SessionStore(config.maxTurns, config.rateLimitPerMinute);
    this.cursorClient = dependencies.cursorClient ?? new CursorClient({});
    this.webhookPendingTtlMs = dependencies.webhookPendingTtlMs ?? WEBHOOK_PENDING_TTL_MS;
    this.now = dependencies.now ?? (() => new Date());
    this.bridgeToolExecutor = dependencies.bridgeToolExecutor;
  }

  createRateLimiter() {
    return this.sessions.createRateLimiter();
  }

  isCursorServerConfigured(): boolean {
    return this.cursorClient.isConfigured();
  }

  getCursorRun(agentId: string): CursorAgentRunRecord | undefined {
    return this.sessions.getCursorRun(agentId);
  }

  getAgentIdForSpawnCall(spawnCallId: string): string | undefined {
    return this.sessions.getAgentIdForSpawnCall(spawnCallId);
  }

  async handleCursorWebhook(
    payload: Record<string, unknown>,
    emit: (event: EventEnvelope) => void,
  ): Promise<CursorWebhookHandleResult> {
    const parsed = parseCursorWebhookPayload(payload);
    if (!parsed) {
      return {
        statusCode: 400,
        payload: {
          error: "invalid_cursor_webhook_payload",
          message: "Missing agentId or unsupported payload shape.",
        },
      };
    }

    const run = this.sessions.getCursorRun(parsed.agent.agentId);
    if (!run) {
      this.sessions.storePendingWebhook(
        parsed.agent.agentId,
        payload,
        this.webhookPendingTtlMs,
        this.now().getTime(),
      );
      logger.warn("cursor webhook agent not yet mapped; queued for retry", {
        agentId: parsed.agent.agentId,
        trace: parsed.eventType,
      });
      return {
        statusCode: 202,
        payload: {
          accepted: true,
          queued: true,
          agentId: parsed.agent.agentId,
        },
      };
    }

    await this.routeWebhookToSession(run.sessionId, parsed, emit);

    return {
      statusCode: 200,
      payload: {
        ok: true,
        sessionId: run.sessionId,
        agentId: parsed.agent.agentId,
      },
    };
  }

  async handleEvent(
    event: EventEnvelope,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const session = this.sessions.getOrCreate(event.sessionId);

    switch (event.type) {
      case "session.start": {
        if (typeof event.payload.githubToken === "string" && event.payload.githubToken) {
          session.githubToken = event.payload.githubToken;
        }
        emit(makeEvent("session.started", event.sessionId, { sessionId: event.sessionId }));
        logger.info("session started", { sessionId: event.sessionId, eventId: event.id });
        return;
      }

      case "user.audio.transcript.final": {
        const text = asString(event.payload.text)?.trim();
        if (!text) {
          emit(makeEvent("error", event.sessionId, {
            code: "invalid_transcript",
            message: "user.audio.transcript.final must include payload.text",
          }));
          return;
        }

        await this.runConductorLoop(session, text, emit, event.id);
        return;
      }

      case "tool.result": {
        const callId = asString(event.payload.callId);
        const resultPayload = asString(event.payload.result);
        const errorText = asString(event.payload.error);

        if (callId) {
          const pending = session.pendingToolCalls.get(callId);
          session.pendingToolCalls.delete(callId);
          logger.info(
            errorText ? `tool.result error: ${errorText}` : "tool.result ok",
            {
              sessionId: session.sessionId,
              eventId: event.id,
              callId,
              trace: pending?.toolName,
            },
          );

          if (!errorText) {
            await this.trackSpawnResultIfPresent(
              session,
              callId,
              pending?.toolName,
              pending?.toolArguments,
              resultPayload,
              emit,
            );
          }

          const resolver = session.toolResultResolvers.get(callId);
          if (resolver) {
            resolver(resultPayload ?? null, errorText ?? null);
          }
        }
        return;
      }

      case "audio.output.interrupted": {
        logger.info("audio output interrupted", {
          sessionId: session.sessionId,
          eventId: event.id,
        });
        return;
      }

      case "agent.completed": {
        const agentId = asString(event.payload.agentId) ?? "unknown";
        const status = asString(event.payload.status) ?? "UNKNOWN";
        const summary = asString(event.payload.summary) ?? "";
        const name = asString(event.payload.name);
        const prompt = asString(event.payload.prompt);

        const outcome = status === "FINISHED" ? "finished successfully" : "failed";
        const agentRef = name ? `"${name}"` : `agent ${agentId}`;
        const taskDesc = prompt ? `Task: "${prompt}". ` : "";
        const summaryDesc = summary ? `Summary: ${summary}` : "No summary was provided.";

        const contextText = [
          `[Agent Update] Cursor agent ${agentRef} just ${outcome}.`,
          taskDesc,
          summaryDesc,
          "Tell the user what the agent accomplished (or what went wrong if it failed),",
          "in a concise, natural sentence or two. Do not repeat the raw summary verbatim.",
        ].join(" ").trim();

        logger.info("agent.completed received", {
          sessionId: session.sessionId,
          eventId: event.id,
          agentId,
          status,
        });

        await this.runConductorLoop(session, contextText, emit, event.id, {
          suppressUserMessage: true,
        });
        return;
      }

      default:
        logger.info(`ignored event type: ${event.type}`, {
          sessionId: session.sessionId,
          eventId: event.id,
        });
        return;
    }
  }

  private availableTools(): ToolDefinition[] {
    const tools: ToolDefinition[] = [...LEGACY_CLIENT_TOOLS];

    if (this.cursorClient.isConfigured()) {
      tools.push(...SERVER_CURSOR_TOOLS);
    }
    if (this.bridgeToolExecutor) {
      tools.push(...SERVER_BRIDGE_TOOLS);
    }

    return tools;
  }

  private shouldExecuteServerTool(toolName: string): boolean {
    if (toolName.startsWith("bridge.")) {
      return Boolean(this.bridgeToolExecutor);
    }

    if (this.cursorClient.isConfigured() && toolName === "repositories.list") {
      return true;
    }

    return this.cursorClient.isConfigured()
      && (toolName.startsWith("cursor.agent.") || toolName.startsWith("webqa.cursor."));
  }

  private async runConductorLoop(
    session: SessionState,
    transcript: string,
    emit: (event: EventEnvelope) => void,
    sourceEventId: string,
    options: { suppressUserMessage?: boolean } = {},
  ): Promise<void> {
    session.transcriptCount += 1;
    session.recentTranscriptTrace = [];

    const tracePush = (value: string): void => {
      session.recentTranscriptTrace.push(value);
      this.sessions.recordTrace(session, value);
    };

    const emitToolCall = (toolName: string, args: Record<string, unknown>): void => {
      const callId = crypto.randomUUID();
      const envelope = makeEvent("tool.call", session.sessionId, {
        callId,
        name: toolName,
        arguments: JSON.stringify(args),
      });

      session.pendingToolCalls.set(callId, {
        callId,
        toolName,
        emittedAt: envelope.timestamp,
        toolArguments: args,
      });

      emit(envelope);
      tracePush(`tool.call:${toolName}`);
    };

    this.sessions.appendTurn(session, {
      role: "user",
      content: transcript,
    });

    emitToolCall("convo.setState", { state: "thinking" });
    if (!options.suppressUserMessage) {
      emitToolCall("convo.appendMessage", {
        role: "user",
        text: transcript,
        isPartial: false,
      });
    }

    const MAX_TOOL_ROUNDS = 8;
    let toolRound = 0;
    let emittedFinalResponse = false;
    const deterministicBridgeToolCall = this.routeDeterministicBridgeIntent(transcript);

    while (toolRound < MAX_TOOL_ROUNDS) {
      toolRound += 1;

      let modelResponse: ModelResponse;
      if (toolRound === 1 && deterministicBridgeToolCall) {
        modelResponse = {
          fullText: "",
          chunks: (async function* stream() {})(),
          toolCalls: [deterministicBridgeToolCall],
        };
      } else {
        try {
          modelResponse = await this.provider.generateResponse(session.history, this.availableTools());
        } catch (error) {
          const message = error instanceof Error ? error.message : "Unknown model provider error";
          emit(makeEvent("error", session.sessionId, {
            code: "model_provider_failed",
            message,
          }));
          emitToolCall("convo.setState", { state: "idle" });
          logger.error(`model provider failed: ${message}`, {
            sessionId: session.sessionId,
            eventId: sourceEventId,
          });
          return;
        }
      }

      if (modelResponse.toolCalls && modelResponse.toolCalls.length > 0) {
        this.sessions.appendTurn(session, {
          role: "assistant",
          content: modelResponse.toolCalls,
        });

        for (const toolCall of modelResponse.toolCalls) {
          const callId = crypto.randomUUID();

          if (this.shouldExecuteServerTool(toolCall.name)) {
            tracePush(`tool.server:${toolCall.name}`);
            const execution = await this.executeServerTool(
              session,
              callId,
              toolCall.name,
              toolCall.input,
              emit,
            );

            this.sessions.appendTurn(session, {
              role: "tool",
              content: execution.error ? `Error: ${execution.error}` : execution.result ?? "{}",
              tool_use_id: toolCall.id,
              tool_name: toolCall.name,
            });
            continue;
          }

          const envelope = makeEvent("tool.call", session.sessionId, {
            callId,
            name: toolCall.name,
            arguments: JSON.stringify(toolCall.input),
          });

          session.pendingToolCalls.set(callId, {
            callId,
            toolName: toolCall.name,
            emittedAt: envelope.timestamp,
            toolArguments: toolCall.input,
          });

          emit(envelope);
          tracePush(`tool.call:${toolCall.name}`);

          const { result, error } = await waitForToolResult(session, callId, 30_000);

          this.sessions.appendTurn(session, {
            role: "tool",
            content: result ?? `Error: ${error ?? "unknown"}`,
            tool_use_id: toolCall.id,
            tool_name: toolCall.name,
          });
        }

        continue;
      }

      let responseText = "";
      for await (const chunk of modelResponse.chunks) {
        responseText += chunk;
        emit(makeEvent("assistant.speech.partial", session.sessionId, { text: responseText }));
        tracePush("assistant.speech.partial");
      }

      if (!responseText.trim()) {
        responseText = modelResponse.fullText;
      }

      responseText = responseText.trim();

      emit(makeEvent("assistant.speech.final", session.sessionId, { text: responseText }));
      tracePush("assistant.speech.final");

      this.sessions.appendTurn(session, {
        role: "assistant",
        content: responseText,
      });

      emitToolCall("convo.appendMessage", {
        role: "assistant",
        text: responseText,
        isPartial: false,
      });
      emitToolCall("convo.setState", { state: "speaking" });
      emitToolCall("tts.speak", { text: responseText });
      emitToolCall("convo.setState", { state: "idle" });

      emittedFinalResponse = true;
      break;
    }

    if (!emittedFinalResponse) {
      emit(makeEvent("error", session.sessionId, {
        code: "tool_round_limit_exceeded",
        message: "Conductor reached max tool rounds without a final response.",
      }));
      emitToolCall("convo.setState", { state: "idle" });
      logger.warn("tool round limit exceeded", {
        sessionId: session.sessionId,
        eventId: sourceEventId,
      });
    }

    const traceLabel = options.suppressUserMessage
      ? `agent.completed trace #${session.transcriptCount}`
      : `transcript.final trace #${session.transcriptCount}`;
    logger.info(
      `${traceLabel}: ${session.recentTranscriptTrace.join(" -> ")}`,
      { sessionId: session.sessionId, eventId: sourceEventId },
    );
  }

  private routeDeterministicBridgeIntent(transcript: string): ToolCallRequest | undefined {
    if (!this.bridgeToolExecutor) {
      return undefined;
    }

    const normalized = transcript.trim();
    if (!normalized) {
      return undefined;
    }

    const lower = normalized.toLowerCase();
    if (lower === "run tests" || lower === "run unit tests") {
      return {
        id: crypto.randomUUID(),
        name: "bridge.exec.run",
        input: { command: "npm test" },
      };
    }

    const runMatch = normalized.match(/^run\s+(.+)$/i);
    if (runMatch) {
      const command = runMatch[1]?.trim();
      if (command) {
        return {
          id: crypto.randomUUID(),
          name: "bridge.exec.run",
          input: { command },
        };
      }
    }

    const readMatch = normalized.match(/^(read file|open file)\s+(.+)$/i);
    if (readMatch) {
      const path = readMatch[2]?.trim();
      if (path) {
        return {
          id: crypto.randomUUID(),
          name: "bridge.fs.readFile",
          input: { path },
        };
      }
    }

    return undefined;
  }

  private async executeServerTool(
    session: SessionState,
    callId: string,
    toolName: string,
    args: Record<string, unknown>,
    emit: (event: EventEnvelope) => void,
  ): Promise<{ result: string | null; error: string | null }> {
    if (!this.cursorClient.isConfigured()) {
      if (toolName.startsWith("cursor.") || toolName.startsWith("webqa.") || toolName === "repositories.list") {
        return {
          result: null,
          error: "cursor_server_not_configured: CURSOR_API_KEY is not configured. Fall back to legacy agent.* tools.",
        };
      }
    }

    try {
      switch (toolName) {
        case "cursor.agent.spawn": {
          const prompt = stringFromRecord(args, "prompt");
          if (!prompt) {
            return { result: null, error: "cursor_invalid_prompt" };
          }

          const metadata = asRecord(args.metadata) ?? {};
          const mode = normalizeMode(stringFromRecord(args, "mode") ?? stringFromRecord(metadata, "mode")) ?? "code";
          const repoUrl = stringFromRecord(args, "repoUrl", "repository");
          const ref = stringFromRecord(args, "ref");

          const spawned = await this.cursorClient.spawnAgent({
            prompt,
            repoUrl,
            ref,
            metadata,
            mode,
          });

          await this.recordSpawn(
            session.sessionId,
            callId,
            mode,
            {
              agentId: spawned.agentId,
              status: spawned.status,
              runUrl: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
              summary: spawned.summary,
            },
            emit,
          );

          return {
            result: stableJSONStringify({
              agentId: spawned.agentId,
              id: spawned.agentId,
              status: spawned.status ?? "CREATING",
              runUrl: spawned.runUrl,
              url: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
            }),
            error: null,
          };
        }

        case "cursor.agent.status": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          const statusResult = await this.cursorClient.status(agentId);
          const existing = this.sessions.getCursorRun(agentId);
          const mode = existing?.mode ?? "code";

          this.sessions.upsertCursorRun({
            agentId,
            sessionId: existing?.sessionId ?? session.sessionId,
            createdAt: existing?.createdAt ?? this.now().toISOString(),
            mode,
            status: statusResult.status,
            runUrl: statusResult.runUrl,
            prUrl: statusResult.prUrl,
            branchName: statusResult.branchName,
            summary: statusResult.summary,
            spawnCallId: existing?.spawnCallId,
          });

          if (isTerminalAgentStatus(statusResult.status)) {
            this.stopConversationPolling(agentId);
          }

          return {
            result: stableJSONStringify({
              agentId,
              status: statusResult.status,
              runUrl: statusResult.runUrl,
              prUrl: statusResult.prUrl,
              summary: statusResult.summary,
            }),
            error: null,
          };
        }

        case "cursor.agent.followup": {
          const agentId = stringFromRecord(args, "agentId", "id");
          const message = stringFromRecord(args, "message", "prompt");
          if (!agentId || !message) {
            return { result: null, error: "cursor_followup_requires_agentId_and_message" };
          }

          await this.cursorClient.followup(agentId, message);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "cursor.agent.cancel": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          await this.cursorClient.cancel(agentId);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "webqa.cursor.run": {
          const url = stringFromRecord(args, "url");
          if (!url) {
            return { result: null, error: "webqa_missing_url" };
          }

          const flowSpec = args.flowSpec ?? {};
          const assertions = args.assertions;
          const budget = args.budget;

          const prompt = this.buildWebQAPrompt(url, flowSpec, assertions, budget);
          const spawned = await this.cursorClient.spawnAgent({
            prompt,
            metadata: {
              mode: "webqa",
              provider: "cursor",
              url,
              flowSpec,
              assertions: assertions ?? null,
              budget: budget ?? null,
            },
            mode: "computer_use",
          });

          await this.recordSpawn(
            session.sessionId,
            callId,
            "webqa",
            {
              agentId: spawned.agentId,
              status: spawned.status,
              runUrl: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
              summary: spawned.summary,
            },
            emit,
          );

          return {
            result: stableJSONStringify({
              agentId: spawned.agentId,
              runUrl: spawned.runUrl,
              status: spawned.status,
            }),
            error: null,
          };
        }

        case "webqa.cursor.status": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          const statusResult = await this.cursorClient.status(agentId);
          return {
            result: stableJSONStringify({
              agentId,
              status: statusResult.status,
              runUrl: statusResult.runUrl,
              prUrl: statusResult.prUrl,
              summary: statusResult.summary,
            }),
            error: null,
          };
        }

        case "webqa.cursor.followup": {
          const agentId = stringFromRecord(args, "agentId", "id");
          const instruction = stringFromRecord(args, "instruction", "message");
          if (!agentId || !instruction) {
            return { result: null, error: "webqa_followup_requires_agentId_and_instruction" };
          }

          await this.cursorClient.followup(agentId, instruction);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "repositories.list": {
          const repositories = await this.cursorClient.repositories();
          return {
            result: stableJSONStringify({
              repositories,
              count: repositories.length,
            }),
            error: null,
          };
        }

        case "bridge.exec.run":
        case "bridge.fs.readFile": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }

          const timeoutSecRaw = typeof args.timeoutSec === "number" ? args.timeoutSec : undefined;
          const timeoutMs = Math.max(1, Math.min(600, Math.trunc(timeoutSecRaw ?? 60))) * 1_000;
          return await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args,
            timeoutMs,
          }, emit);
        }

        default:
          return { result: null, error: `unsupported_server_tool:${toolName}` };
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown_server_tool_error";
      logger.warn(`server tool execution failed: ${toolName}: ${message}`, {
        sessionId: session.sessionId,
        callId,
      });
      return { result: null, error: message };
    }
  }

  private buildWebQAPrompt(
    url: string,
    flowSpec: unknown,
    assertions: unknown,
    budget: unknown,
  ): string {
    return [
      "You are executing a deterministic browser QA run.",
      `TARGET_URL: ${url}`,
      "FLOW_SPEC_JSON:",
      stableJSONStringify(flowSpec ?? {}),
      "ASSERTIONS_JSON:",
      stableJSONStringify(assertions ?? {}),
      "BUDGET_JSON:",
      stableJSONStringify(budget ?? {}),
      "Instructions:",
      "1) Open TARGET_URL in the browser.",
      "2) Execute flow steps exactly in order from FLOW_SPEC_JSON.",
      "3) Capture available artifacts (screenshots, video, logs).",
      "4) Summarize pass/fail for each assertion.",
      "5) Include console/network errors if observed.",
    ].join("\n");
  }

  private async trackSpawnResultIfPresent(
    session: SessionState,
    spawnCallId: string,
    toolName: string | undefined,
    toolArguments: Record<string, unknown> | undefined,
    resultPayload: string | undefined,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    if (!toolName || !resultPayload) {
      return;
    }

    const isSpawnTool = toolName === "agent.spawn"
      || toolName === "cursor.agent.spawn"
      || toolName === "webqa.cursor.run";

    if (!isSpawnTool) {
      return;
    }

    const snapshot = parseCursorAgentSnapshotFromResult(resultPayload);
    if (!snapshot) {
      return;
    }

    const modeFromArgs = normalizeMode(stringFromRecord(toolArguments ?? {}, "mode"));
    const mode: CursorAgentMode = modeFromArgs
      ?? snapshot.mode
      ?? (toolName === "webqa.cursor.run" ? "webqa" : "code");

    await this.recordSpawn(
      session.sessionId,
      spawnCallId,
      mode,
      {
        agentId: snapshot.agentId,
        status: snapshot.status,
        runUrl: snapshot.runUrl,
        prUrl: snapshot.prUrl,
        branchName: snapshot.branchName,
        summary: snapshot.summary,
      },
      emit,
    );
  }

  private async recordSpawn(
    sessionId: string,
    spawnCallId: string,
    mode: CursorAgentMode,
    details: {
      agentId: string;
      status?: string;
      runUrl?: string;
      prUrl?: string;
      branchName?: string;
      summary?: string;
    },
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const run = this.sessions.upsertCursorRun({
      agentId: details.agentId,
      sessionId,
      createdAt: this.now().toISOString(),
      mode,
      status: details.status,
      runUrl: details.runUrl,
      prUrl: details.prUrl,
      branchName: details.branchName,
      summary: details.summary,
      spawnCallId,
    });

    this.sessions.setSpawnCallAgent(spawnCallId, details.agentId);

    this.emitAgentStatus(run, emit, {
      eventSeed: `spawn:${spawnCallId}`,
      webhookDriven: this.cursorClient.hasWebhookConfig(),
    });

    this.startConversationPolling(details.agentId, sessionId, emit);

    const pending = this.sessions.takePendingWebhook(run.agentId, this.now().getTime());
    if (!pending) {
      return;
    }

    const parsed = parseCursorWebhookPayload(pending.payload);
    if (!parsed) {
      return;
    }

    await this.routeWebhookToSession(sessionId, parsed, emit);
  }

  private async routeWebhookToSession(
    sessionId: string,
    parsedWebhook: ParsedCursorWebhookEvent,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const normalizedStatus = normalizeStatus(parsedWebhook.agent.status) ?? "UNKNOWN";
    const existing = this.sessions.getCursorRun(parsedWebhook.agent.agentId);
    const updatedRun = this.sessions.upsertCursorRun({
      agentId: parsedWebhook.agent.agentId,
      sessionId,
      createdAt: this.now().toISOString(),
      mode: parsedWebhook.agent.mode ?? existing?.mode ?? "code",
      status: normalizedStatus,
      runUrl: parsedWebhook.agent.runUrl,
      prUrl: parsedWebhook.agent.prUrl,
      branchName: parsedWebhook.agent.branchName,
      summary: parsedWebhook.agent.summary,
    });

    this.emitAgentStatus(updatedRun, emit, {
      eventSeed: `webhook:${parsedWebhook.eventType ?? "unknown"}:${parsedWebhook.occurredAt ?? "na"}:${normalizedStatus}`,
      webhookDriven: true,
      timestamp: parsedWebhook.occurredAt,
    });

    if (!isTerminalAgentStatus(normalizedStatus)) {
      this.startConversationPolling(parsedWebhook.agent.agentId, sessionId, emit);
      return;
    }

    this.stopConversationPolling(parsedWebhook.agent.agentId);

    const completedPayload: Record<string, unknown> = {
      agentId: updatedRun.agentId,
      status: normalizedStatus,
      summary: updatedRun.summary ?? "",
      runUrl: updatedRun.runUrl,
      prUrl: updatedRun.prUrl,
      branchName: updatedRun.branchName,
    };

    const completedTimestamp = parsedWebhook.occurredAt ?? this.now().toISOString();
    const completedId = makeDeterministicEventId([
      "agent.completed",
      sessionId,
      updatedRun.agentId,
      normalizedStatus,
      completedTimestamp,
    ].join("|"));

    await this.handleEvent(
      makeEvent("agent.completed", sessionId, completedPayload, completedId, completedTimestamp),
      emit,
    );
  }

  private emitAgentStatus(
    run: CursorAgentRunRecord,
    emit: (event: EventEnvelope) => void,
    options: {
      eventSeed: string;
      webhookDriven: boolean;
      timestamp?: string;
    },
  ): void {
    const status = normalizeStatus(run.status) ?? "UNKNOWN";
    const timestamp = options.timestamp ?? this.now().toISOString();
    const eventId = makeDeterministicEventId([
      "agent.status",
      run.sessionId,
      run.agentId,
      status,
      options.eventSeed,
    ].join("|"));

    emit(makeEvent(
      "agent.status",
      run.sessionId,
      {
        agentId: run.agentId,
        status,
        detail: run.summary ?? `Agent status updated: ${status}`,
        summary: run.summary,
        runUrl: run.runUrl,
        prUrl: run.prUrl,
        branchName: run.branchName,
        webhookDriven: options.webhookDriven,
      },
      eventId,
      timestamp,
    ));
  }

  private startConversationPolling(
    agentId: string,
    sessionId: string,
    emit: (event: EventEnvelope) => void,
  ): void {
    if (this.conversationPollers.has(agentId)) {
      return;
    }

    const poll = async (): Promise<void> => {
      const run = this.sessions.getCursorRun(agentId);
      if (!run || isTerminalAgentStatus(run.status)) {
        this.stopConversationPolling(agentId);
        await this.pollConversation(agentId, sessionId, emit);
        return;
      }
      await this.pollConversation(agentId, sessionId, emit);
    };

    const timer = setInterval(poll, ConductorService.CONVERSATION_POLL_INTERVAL_MS);
    this.conversationPollers.set(agentId, timer);
    poll().catch(() => {});
  }

  private stopConversationPolling(agentId: string): void {
    const timer = this.conversationPollers.get(agentId);
    if (timer) {
      clearInterval(timer);
      this.conversationPollers.delete(agentId);
    }
  }

  private async pollConversation(
    agentId: string,
    sessionId: string,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    try {
      const result = await this.cursorClient.conversation(agentId);
      const run = this.sessions.getCursorRun(agentId);
      const lastSeenId = run?.lastSeenConversationMessageId;

      let newMessages = result.messages;
      if (lastSeenId) {
        const lastSeenIndex = result.messages.findIndex((m) => m.id === lastSeenId);
        if (lastSeenIndex >= 0) {
          newMessages = result.messages.slice(lastSeenIndex + 1);
        }
      }

      if (newMessages.length === 0) {
        return;
      }

      const lastMsg = newMessages[newMessages.length - 1]!;
      if (run) {
        run.lastSeenConversationMessageId = lastMsg.id;
      }

      const eventId = makeDeterministicEventId(
        `agent.conversation|${agentId}|${lastMsg.id}`,
      );

      emit(makeEvent("agent.conversation", sessionId, {
        agentId,
        messages: newMessages.map((m) => ({
          id: m.id,
          type: m.type,
          text: m.text,
        })),
      }, eventId));
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown";
      logger.warn(`conversation poll failed for ${agentId}: ${message}`, { agentId });
    }
  }
}

function stableJSONStringify(value: unknown): string {
  const serialized = JSON.stringify(sortJSONValue(value));
  return serialized ?? "null";
}

function sortJSONValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => sortJSONValue(item));
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  const entries = Object.entries(value as Record<string, unknown>)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, nested]) => [key, sortJSONValue(nested)] as const);

  return Object.fromEntries(entries);
}

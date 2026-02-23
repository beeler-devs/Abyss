import crypto from "node:crypto";
import { ToolRegistry } from "../stage3/tools/registry.js";
import { asString, makeEvent } from "./events.js";
import { logger } from "./logger.js";
import { SessionStore } from "./sessionStore.js";
import {
  EventEnvelope,
  ModelProvider,
  ModelResponse,
  SessionState,
  ToolDefinition,
} from "./types.js";

export interface ConductorServiceConfig {
  maxTurns: number;
  rateLimitPerMinute: number;
  toolRegistry?: ToolRegistry;
}

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

export class ConductorService {
  private readonly provider: ModelProvider;
  private readonly sessions: SessionStore;
  private readonly toolRegistry: ToolRegistry;

  constructor(provider: ModelProvider, config: ConductorServiceConfig) {
    this.provider = provider;
    this.sessions = new SessionStore(config.maxTurns, config.rateLimitPerMinute);
    this.toolRegistry = config.toolRegistry ?? new ToolRegistry();
  }

  createRateLimiter() {
    return this.sessions.createRateLimiter();
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
        if (typeof event.payload.selectedRepo === "string" && event.payload.selectedRepo) {
          session.selectedRepo = event.payload.selectedRepo;
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

  private modelTools(): ToolDefinition[] {
    return this.toolRegistry.getDefinitions();
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

    const emitClientToolCall = (toolName: string, args: Record<string, unknown>): string => {
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
      });

      emit(envelope);
      tracePush(`tool.call:${toolName}`);
      return callId;
    };

    this.sessions.appendTurn(session, {
      role: "user",
      content: transcript,
    });

    emitClientToolCall("convo.setState", { state: "thinking" });
    if (!options.suppressUserMessage) {
      emitClientToolCall("convo.appendMessage", {
        role: "user",
        text: transcript,
        isPartial: false,
      });
    }

    const MAX_TOOL_ROUNDS = 10;
    let toolRound = 0;
    let emittedFinalResponse = false;

    while (toolRound < MAX_TOOL_ROUNDS) {
      toolRound += 1;

      let modelResponse: ModelResponse;
      try {
        modelResponse = await this.provider.generateResponse(session.history, this.modelTools());
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown model provider error";
        emit(makeEvent("error", session.sessionId, {
          code: "model_provider_failed",
          message,
        }));
        emitClientToolCall("convo.setState", { state: "idle" });
        logger.error(`model provider failed: ${message}`, {
          sessionId: session.sessionId,
          eventId: sourceEventId,
        });
        return;
      }

      if (modelResponse.toolCalls && modelResponse.toolCalls.length > 0) {
        this.sessions.appendTurn(session, {
          role: "assistant",
          content: modelResponse.toolCalls,
        });

        for (const toolCall of modelResponse.toolCalls) {
          if (this.toolRegistry.isServerTool(toolCall.name)) {
            emit(makeEvent("agent.status", session.sessionId, {
              status: "server_tool",
              detail: `Running ${toolCall.name}`,
              callId: toolCall.id,
            }));
            tracePush(`server.tool.call:${toolCall.name}`);

            const serverResult = await this.toolRegistry.executeServerTool(
              toolCall.name,
              {
                session,
                emit,
              },
              toolCall.input,
            );

            if (serverResult.ok) {
              this.sessions.appendTurn(session, {
                role: "tool",
                content: JSON.stringify(serverResult.result ?? {}),
                tool_use_id: toolCall.id,
                tool_name: toolCall.name,
              });
              emit(makeEvent("agent.status", session.sessionId, {
                status: "server_tool",
                detail: `Completed ${toolCall.name}`,
                callId: toolCall.id,
              }));
              tracePush(`server.tool.result:${toolCall.name}`);
            } else {
              const errorText = serverResult.error ?? "unknown_server_tool_error";
              this.sessions.appendTurn(session, {
                role: "tool",
                content: `Error: ${errorText}`,
                tool_use_id: toolCall.id,
                tool_name: toolCall.name,
              });
              emit(makeEvent("error", session.sessionId, {
                code: "server_tool_failed",
                message: `${toolCall.name}: ${errorText}`,
              }));
              tracePush(`server.tool.error:${toolCall.name}`);
            }
            continue;
          }

          if (!this.toolRegistry.isClientTool(toolCall.name)) {
            this.sessions.appendTurn(session, {
              role: "tool",
              content: `Error: Unknown tool ${toolCall.name}`,
              tool_use_id: toolCall.id,
              tool_name: toolCall.name,
            });
            tracePush(`tool.unknown:${toolCall.name}`);
            continue;
          }

          const callId = emitClientToolCall(toolCall.name, toolCall.input);
          const { result, error } = await waitForToolResult(session, callId, 45_000);

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

      emitClientToolCall("convo.appendMessage", {
        role: "assistant",
        text: responseText,
        isPartial: false,
      });
      emitClientToolCall("convo.setState", { state: "speaking" });
      emitClientToolCall("tts.speak", { text: responseText });
      emitClientToolCall("convo.setState", { state: "idle" });

      emittedFinalResponse = true;
      break;
    }

    if (!emittedFinalResponse) {
      emit(makeEvent("error", session.sessionId, {
        code: "tool_round_limit_exceeded",
        message: "Conductor reached max tool rounds without a final response.",
      }));
      emitClientToolCall("convo.setState", { state: "idle" });
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
}

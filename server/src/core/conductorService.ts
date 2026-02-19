import crypto from "node:crypto";
import { asString, makeEvent } from "./events.js";
import { logger } from "./logger.js";
import { SessionStore } from "./sessionStore.js";
import { EventEnvelope, GenerateOptions, ModelProvider, SessionState } from "./types.js";

export interface ConductorServiceConfig {
  maxTurns: number;
  rateLimitPerMinute: number;
}

export class ConductorService {
  private readonly provider: ModelProvider;
  private readonly sessions: SessionStore;

  constructor(provider: ModelProvider, config: ConductorServiceConfig) {
    this.provider = provider;
    this.sessions = new SessionStore(config.maxTurns, config.rateLimitPerMinute);
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
          logger.info("session started with github token", { sessionId: event.sessionId, eventId: event.id });
        } else {
          logger.info("session started", { sessionId: event.sessionId, eventId: event.id });
        }
        emit(makeEvent("session.started", event.sessionId, { sessionId: event.sessionId }));
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

      default:
        logger.info(`ignored event type: ${event.type}`, {
          sessionId: session.sessionId,
          eventId: event.id,
        });
        return;
    }
  }

  private async runConductorLoop(
    session: SessionState,
    transcript: string,
    emit: (event: EventEnvelope) => void,
    sourceEventId: string,
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
      });

      emit(envelope);
      tracePush(`tool.call:${toolName}`);
    };

    this.sessions.appendTurn(session, {
      role: "user",
      content: transcript,
    });

    emitToolCall("convo.setState", { state: "thinking" });
    emitToolCall("convo.appendMessage", {
      role: "user",
      text: transcript,
      isPartial: false,
    });

    let responseText = "";

    const generateOptions: GenerateOptions = {
      githubToken: session.githubToken,
    };

    try {
      const modelResponse = await this.provider.generateResponse(session.history, generateOptions);
      for await (const chunk of modelResponse.chunks) {
        responseText += chunk;
        emit(makeEvent("assistant.speech.partial", session.sessionId, { text: responseText }));
        tracePush("assistant.speech.partial");
      }

      if (!responseText.trim()) {
        responseText = modelResponse.fullText;
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown model provider error";
      emit(makeEvent("error", session.sessionId, {
        code: "model_provider_failed",
        message,
      }));
      emitToolCall("convo.setState", { state: "idle" });
      logger.error("model provider failed", {
        sessionId: session.sessionId,
        eventId: sourceEventId,
      });
      return;
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

    logger.info(
      `transcript.final trace #${session.transcriptCount}: ${session.recentTranscriptTrace.join(" -> ")}`,
      { sessionId: session.sessionId, eventId: sourceEventId },
    );
  }
}

import crypto from "node:crypto";

import {
  BedrockRuntimeClient,
  InvokeModelWithBidirectionalStreamCommand,
  InvokeModelWithBidirectionalStreamInput,
  InvokeModelWithBidirectionalStreamOutput,
} from "@aws-sdk/client-bedrock-runtime";
import { NodeHttp2Handler } from "@smithy/node-http-handler";

import { makeEvent } from "../core/events.js";
import { logger } from "../core/logger.js";
import { ToolCallRequest, ToolDefinition } from "../core/types.js";
import { VoiceProvider, VoiceProviderContext } from "./types.js";

export interface BedrockNovaSonicVoiceProviderConfig {
  modelId: string;
  region: string;
  voiceId: string;
  enableTools?: boolean;
  assistantTurnFinalizeDelayMs?: number;
}

interface BidirectionalClientLike {
  send(command: InvokeModelWithBidirectionalStreamCommand): Promise<{
    body?: AsyncIterable<InvokeModelWithBidirectionalStreamOutput>;
  }>;
}

interface SonicContentInfo {
  role: string;
  type: string;
  generationStage?: string;
  text: string;
}

interface PendingToolUse {
  toolName: string;
  toolUseId: string;
  content: string;
}

interface SonicSession {
  sessionId: string;
  promptName: string;
  audioContentName: string;
  outgoing: AsyncPushQueue<InvokeModelWithBidirectionalStreamInput>;
  context: VoiceProviderContext;
  responseTask: Promise<void>;
  closed: boolean;
  sawAssistantAudio: boolean;
  contents: Map<string, SonicContentInfo>;
  pendingToolUse: PendingToolUse | null;
  /** Maps sanitized tool names (underscores) back to original names (dots). */
  toolNameMap: Map<string, string>;
  /** Accumulates all FINAL assistant text sentences within a single response turn. */
  accumulatedAssistantText: string;
  liveResponseId: string | null;
  pendingAssistantTurnFinalizeTimer: ReturnType<typeof setTimeout> | null;
  pendingAssistantTurnFinalizeResponseId: string | null;
  toolExecutionInFlight: boolean;
  bufferedAudioChunks: string[];
  restarting: boolean;
  streamGeneration: number;
  bargedIn: boolean;
  /** Tracks consecutive failures per tool name for circuit-breaking. */
  toolFailureCounts: Map<string, number>;
}

interface SonicEventEnvelope {
  event?: Record<string, unknown>;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function parseAdditionalModelFields(value: unknown): Record<string, unknown> {
  if (typeof value !== "string" || value.trim().length === 0) {
    return {};
  }
  try {
    const parsed = JSON.parse(value) as unknown;
    return asRecord(parsed) ?? {};
  } catch {
    return {};
  }
}

const VOICE_PIPELINE_TOOL_PREFIXES = ["stt.", "tts.", "convo."] as const;
const DEFAULT_ASSISTANT_TURN_FINALIZE_DELAY_MS = 500;
const MAX_BUFFERED_AUDIO_CHUNKS = 64;

/** Sanitize tool name for Nova Sonic — only [a-zA-Z0-9_] allowed. */
function sanitizeToolName(name: string): string {
  return name.replace(/[^a-zA-Z0-9_]/g, "_");
}

function convertToolsForSonic(
  tools: ToolDefinition[],
): { config: Record<string, unknown>; nameMap: Map<string, string> } | undefined {
  const eligible = tools.filter(
    (t) => !VOICE_PIPELINE_TOOL_PREFIXES.some((prefix) => t.name.startsWith(prefix)),
  );
  if (eligible.length === 0) {
    return undefined;
  }

  const nameMap = new Map<string, string>();

  const config = {
    tools: eligible.map((t) => {
      const sanitized = sanitizeToolName(t.name);
      nameMap.set(sanitized, t.name);
      return {
        toolSpec: {
          name: sanitized,
          description: t.description,
          inputSchema: {
            json: JSON.stringify({
              type: t.input_schema.type,
              properties: t.input_schema.properties,
              ...(t.input_schema.required ? { required: t.input_schema.required } : {}),
            }),
          },
        },
      };
    }),
  };

  return { config, nameMap };
}

export class BedrockNovaSonicVoiceProvider implements VoiceProvider {
  readonly name = "nova-sonic";

  private readonly config: BedrockNovaSonicVoiceProviderConfig;
  private readonly client: BidirectionalClientLike;
  private readonly sessions = new Map<string, SonicSession>();
  private readonly encoder = new TextEncoder();
  private readonly decoder = new TextDecoder();
  private readonly assistantTurnFinalizeDelayMs: number;

  constructor(config: BedrockNovaSonicVoiceProviderConfig, client?: BidirectionalClientLike) {
    this.config = config;
    this.client = client ?? new BedrockRuntimeClient({
      region: config.region,
      requestHandler: new NodeHttp2Handler({
        requestTimeout: 300_000,
        sessionTimeout: 300_000,
        disableConcurrentStreams: false,
        maxConcurrentStreams: 20,
      }),
    });
    this.assistantTurnFinalizeDelayMs = Math.max(
      0,
      config.assistantTurnFinalizeDelayMs ?? DEFAULT_ASSISTANT_TURN_FINALIZE_DELAY_MS,
    );
  }

  async startStream(sessionId: string, context: VoiceProviderContext): Promise<void> {
    const existing = this.sessions.get(sessionId);
    if (existing) {
      existing.context = context;
      if (!existing.closed && !existing.restarting) {
        this.emitListeningState(existing);
      }
      return;
    }

    const session: SonicSession = {
      sessionId,
      promptName: "",
      audioContentName: "",
      outgoing: new AsyncPushQueue<InvokeModelWithBidirectionalStreamInput>(),
      context,
      responseTask: Promise.resolve(),
      closed: false,
      sawAssistantAudio: false,
      contents: new Map(),
      pendingToolUse: null,
      toolNameMap: new Map(),
      accumulatedAssistantText: "",
      liveResponseId: null,
      pendingAssistantTurnFinalizeTimer: null,
      pendingAssistantTurnFinalizeResponseId: null,
      toolExecutionInFlight: false,
      bufferedAudioChunks: [],
      restarting: false,
      streamGeneration: 0,
      bargedIn: false,
      toolFailureCounts: new Map(),
    };
    this.sessions.set(sessionId, session);
    await this.openModelStream(session);
    this.emitListeningState(session);
  }

  async appendAudioChunk(sessionId: string, base64Audio: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session || session.closed || !base64Audio) {
      return;
    }

    if (session.restarting) {
      session.bufferedAudioChunks.push(base64Audio);
      if (session.bufferedAudioChunks.length > MAX_BUFFERED_AUDIO_CHUNKS) {
        session.bufferedAudioChunks.shift();
      }
      return;
    }

    this.sendAudioInput(session, base64Audio);
  }

  async endStream(_sessionId: string): Promise<void> {
    // No-op — the client sends trailing silence before the end event to
    // trigger Nova Sonic's server-side VAD. The audio content stream stays
    // open for the duration of the session.
  }

  async interrupt(sessionId: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }
    this.handleBargeIn(session, "user_interrupt");
  }

  async closeSession(sessionId: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session || session.closed) {
      return;
    }

    this.beginSessionShutdown(session);
    try {
      await session.responseTask;
    } finally {
      this.deleteSessionIfCurrent(session);
    }
  }

  private async openModelStream(session: SonicSession): Promise<void> {
    const outgoing = new AsyncPushQueue<InvokeModelWithBidirectionalStreamInput>();
    const promptName = `prompt-${crypto.randomUUID()}`;
    const audioContentName = `audio-${crypto.randomUUID()}`;
    session.outgoing = outgoing;
    session.promptName = promptName;
    session.audioContentName = audioContentName;
    session.restarting = false;
    session.streamGeneration += 1;

    const rawTools = session.context.listTools(session.sessionId);
    const toolResult = this.config.enableTools !== false
      ? convertToolsForSonic(rawTools)
      : undefined;
    const toolConfiguration = toolResult?.config;
    const toolCount = toolConfiguration
      ? (toolConfiguration.tools as unknown[]).length
      : 0;
    if (toolResult) {
      session.toolNameMap = toolResult.nameMap;
    } else {
      session.toolNameMap = new Map();
    }
    logger.info(`tools configured: ${toolCount} (enableTools=${this.config.enableTools})`, { sessionId: session.sessionId });
    if (toolCount > 0) {
      logger.info(`tool names: ${[...session.toolNameMap.keys()].join(", ")}`, { sessionId: session.sessionId });
    }

    // Queue ALL setup events BEFORE calling send() — the SDK starts consuming
    // the iterator immediately and expects sessionStart as the first event.
    // Nova Sonic docs: use temperature 0 when tools are enabled
    this.sendEvent(session, {
      sessionStart: {
        inferenceConfiguration: {
          maxTokens: 1024,
          temperature: toolCount > 0 ? 0 : 0.7,
          topP: 0.9,
        },
      },
    });

    const promptStartPayload: Record<string, unknown> = {
      promptName,
      textOutputConfiguration: {
        mediaType: "text/plain",
      },
      audioOutputConfiguration: {
        audioType: "SPEECH",
        encoding: "base64",
        mediaType: "audio/lpcm",
        sampleRateHertz: 24000,
        sampleSizeBits: 16,
        channelCount: 1,
        voiceId: this.config.voiceId,
      },
    };
    if (toolConfiguration) {
      promptStartPayload.toolUseOutputConfiguration = {
        mediaType: "application/json",
      };
      promptStartPayload.toolConfiguration = toolConfiguration;
    }
    this.sendEvent(session, { promptStart: promptStartPayload });

    const toolsLine = toolCount > 0
      ? ` You have access to ${toolCount} tools including code execution, file operations, git, and agent spawning. Call them one at a time.`
      : "";
    const systemPrompt = `You are the Abyss voice-first coding assistant. Keep responses concise, practical, and voice-friendly.${toolsLine}`;

    const systemContentName = `system-${crypto.randomUUID()}`;
    this.sendEvent(session, {
      contentStart: {
        promptName,
        contentName: systemContentName,
        type: "TEXT",
        interactive: false,
        role: "SYSTEM",
        textInputConfiguration: {
          mediaType: "text/plain",
        },
      },
    });
    this.sendEvent(session, {
      textInput: {
        promptName,
        contentName: systemContentName,
        content: systemPrompt,
      },
    });
    this.sendEvent(session, {
      contentEnd: {
        promptName,
        contentName: systemContentName,
      },
    });

    this.sendEvent(session, {
      contentStart: {
        promptName,
        contentName: audioContentName,
        type: "AUDIO",
        interactive: true,
        role: "USER",
        audioInputConfiguration: {
          audioType: "SPEECH",
          encoding: "base64",
          mediaType: "audio/lpcm",
          sampleRateHertz: 16000,
          sampleSizeBits: 16,
          channelCount: 1,
        },
      },
    });

    // NOW start the bidirectional stream — events are already queued
    const response = await this.client.send(new InvokeModelWithBidirectionalStreamCommand({
      modelId: this.config.modelId,
      body: outgoing,
    }));

    const streamGeneration = session.streamGeneration;
    session.responseTask = this.consumeResponseStream(session, response.body, streamGeneration);

    for (const bufferedAudio of session.bufferedAudioChunks.splice(0)) {
      this.sendAudioInput(session, bufferedAudio);
    }
  }

  private emitListeningState(session: SonicSession): void {
    session.context.emit(makeEvent("tool.call", session.sessionId, {
      callId: crypto.randomUUID(),
      name: "convo.setState",
      arguments: JSON.stringify({ state: "listening" }),
    }));
  }

  private sendAudioInput(session: SonicSession, base64Audio: string): void {
    this.sendEvent(session, {
      audioInput: {
        promptName: session.promptName,
        contentName: session.audioContentName,
        content: base64Audio,
      },
    });
  }

  private async consumeResponseStream(
    session: SonicSession,
    body: AsyncIterable<InvokeModelWithBidirectionalStreamOutput> | undefined,
    streamGeneration: number,
  ): Promise<void> {
    if (!body) {
      return;
    }

    try {
      for await (const frame of body) {
        if (session.closed || streamGeneration !== session.streamGeneration) {
          continue;
        }

        if ("chunk" in frame && frame.chunk?.bytes) {
          const raw = this.decoder.decode(frame.chunk.bytes);
          this.handleOutputEvent(session, raw);
          continue;
        }

        const errorFrame = (
          ("internalServerException" in frame && frame.internalServerException?.message)
          || ("modelStreamErrorException" in frame && frame.modelStreamErrorException?.message)
          || ("validationException" in frame && frame.validationException?.message)
          || ("throttlingException" in frame && frame.throttlingException?.message)
          || ("modelTimeoutException" in frame && frame.modelTimeoutException?.message)
          || ("serviceUnavailableException" in frame && frame.serviceUnavailableException?.message)
        );
        if (errorFrame) {
          await this.handleSessionFailure(session, String(errorFrame));
          break;
        }
      }
    } catch (error) {
      if (session.closed || streamGeneration !== session.streamGeneration) {
        return;
      }
      const message = error instanceof Error ? error.message : JSON.stringify(error, null, 2);
      logger.error(`voice provider failed: ${message}`, { sessionId: session.sessionId });
      await this.handleSessionFailure(session, message);
    }
  }

  private cancelPendingAssistantTurnFinalize(session: SonicSession): void {
    if (session.pendingAssistantTurnFinalizeTimer) {
      clearTimeout(session.pendingAssistantTurnFinalizeTimer);
      session.pendingAssistantTurnFinalizeTimer = null;
    }
    session.pendingAssistantTurnFinalizeResponseId = null;
  }

  private noteAssistantActivity(session: SonicSession): void {
    this.cancelPendingAssistantTurnFinalize(session);
  }

  private hasOpenAssistantTurn(session: SonicSession): boolean {
    return session.accumulatedAssistantText.trim().length > 0
      || session.sawAssistantAudio
      || session.liveResponseId !== null;
  }

  private finalizeAccumulatedAssistantText(session: SonicSession): boolean {
    const text = session.accumulatedAssistantText.trim();
    if (!text) {
      session.accumulatedAssistantText = "";
      return false;
    }

    const liveResponseId = this.ensureLiveResponseId(session);

    session.context.emit(makeEvent("assistant.speech.final", session.sessionId, {
      text,
      liveResponseId,
    }));
    session.context.emit(makeEvent("tool.call", session.sessionId, {
      callId: crypto.randomUUID(),
      name: "convo.appendMessage",
      arguments: JSON.stringify({
        role: "assistant",
        text,
        isPartial: false,
        liveResponseId,
      }),
    }));
    session.accumulatedAssistantText = "";
    session.liveResponseId = null;
    return true;
  }

  private finishAssistantTurn(
    session: SonicSession,
    options: {
      emitIdle: boolean;
      reason: "completion_end" | "audio_end_fallback" | "user_turn_flush";
    },
  ): void {
    this.cancelPendingAssistantTurnFinalize(session);

    if (!this.hasOpenAssistantTurn(session)) {
      return;
    }

    this.finalizeAccumulatedAssistantText(session);

    if (options.emitIdle) {
      session.context.emit(makeEvent("tool.call", session.sessionId, {
        callId: crypto.randomUUID(),
        name: "convo.setState",
        arguments: JSON.stringify({ state: "idle" }),
      }));
    }

    session.sawAssistantAudio = false;
    session.liveResponseId = null;
  }

  private scheduleAssistantTurnFinalize(session: SonicSession): void {
    this.cancelPendingAssistantTurnFinalize(session);

    if (session.closed) {
      return;
    }
    if (!session.accumulatedAssistantText.trim()) {
      return;
    }
    if (session.pendingToolUse || session.toolExecutionInFlight) {
      return;
    }

    const liveResponseId = session.liveResponseId;
    if (!liveResponseId) {
      return;
    }

    session.pendingAssistantTurnFinalizeResponseId = liveResponseId;
    session.pendingAssistantTurnFinalizeTimer = setTimeout(() => {
      session.pendingAssistantTurnFinalizeTimer = null;

      if (session.closed) {
        session.pendingAssistantTurnFinalizeResponseId = null;
        return;
      }
      if (session.pendingAssistantTurnFinalizeResponseId !== liveResponseId) {
        session.pendingAssistantTurnFinalizeResponseId = null;
        return;
      }
      if (session.liveResponseId !== liveResponseId) {
        session.pendingAssistantTurnFinalizeResponseId = null;
        return;
      }
      if (session.pendingToolUse || session.toolExecutionInFlight) {
        session.pendingAssistantTurnFinalizeResponseId = null;
        return;
      }

      this.finishAssistantTurn(session, {
        emitIdle: true,
        reason: "audio_end_fallback",
      });
    }, this.assistantTurnFinalizeDelayMs);
  }

  private handleOutputEvent(session: SonicSession, raw: string): void {
    if (session.closed) {
      return;
    }

    const parsed = this.tryParseEnvelope(raw);
    if (!parsed?.event) {
      return;
    }

    const event = parsed.event;
    // Log tool-related and key lifecycle events (skip verbose audio/usage)
    if ("toolUse" in event || ("contentEnd" in event && asRecord(event.contentEnd)?.type === "TOOL")) {
      logger.info(`sonic output: ${JSON.stringify(event).slice(0, 500)}`, { sessionId: session.sessionId });
    }
    if ("contentStart" in event) {
      const payload = asRecord(event.contentStart);
      if (!payload) {
        return;
      }
      const contentId = asString(payload.contentId) ?? asString(payload.contentName);
      if (!contentId) {
        return;
      }
      const metadata = parseAdditionalModelFields(payload.additionalModelFields);
      session.contents.set(contentId, {
        role: asString(payload.role) ?? "ASSISTANT",
        type: asString(payload.type) ?? "TEXT",
        generationStage: asString(metadata.generationStage),
        text: "",
      });
      const role = asString(payload.role) ?? "ASSISTANT";
      if (role === "ASSISTANT") {
        this.noteAssistantActivity(session);
      }
      if (role === "USER") {
        session.bargedIn = false;
      }
      return;
    }

    if ("textOutput" in event) {
      const payload = asRecord(event.textOutput);
      const contentId = payload ? (asString(payload.contentId) ?? asString(payload.contentName)) : undefined;
      const content = payload ? asString(payload.content) : undefined;
      if (!contentId || typeof content !== "string") {
        return;
      }
      const info = session.contents.get(contentId);
      if (!info) {
        return;
      }
      if (info.role === "ASSISTANT" && session.bargedIn) return;
      info.text += content;
      if (info.role === "ASSISTANT") {
        this.noteAssistantActivity(session);
        this.ensureLiveResponseId(session);
      }

      if (info.role === "ASSISTANT" && info.generationStage === "SPECULATIVE") {
        const liveResponseId = this.ensureLiveResponseId(session);
        const preview = session.accumulatedAssistantText
          ? session.accumulatedAssistantText + " " + info.text
          : info.text;
        session.context.emit(makeEvent("assistant.speech.partial", session.sessionId, {
          text: preview,
          liveResponseId,
        }));
      }
      return;
    }

    if ("audioOutput" in event) {
      if (session.bargedIn) return;
      const payload = asRecord(event.audioOutput);
      const audio = payload ? (asString(payload.content) ?? asString(payload.bytes)) : undefined;
      if (!audio) {
        return;
      }
      this.noteAssistantActivity(session);
      if (!session.sawAssistantAudio) {
        session.sawAssistantAudio = true;
        session.context.emit(makeEvent("tool.call", session.sessionId, {
          callId: crypto.randomUUID(),
          name: "convo.setState",
          arguments: JSON.stringify({ state: "speaking" }),
        }));
      }
      const liveResponseId = this.ensureLiveResponseId(session);
      session.context.emit(makeEvent("assistant.audio.chunk", session.sessionId, {
        audio,
        encoding: "pcm_s16le",
        sampleRateHertz: 24000,
        channelCount: 1,
        liveResponseId,
      }));
      return;
    }

    if ("toolUse" in event) {
      const payload = asRecord(event.toolUse);
      if (!payload) {
        return;
      }
      const sanitizedName = asString(payload.toolName) ?? asString(payload.name);
      const toolUseId = asString(payload.toolUseId);
      const content = asString(payload.content) ?? "{}";
      if (!sanitizedName || !toolUseId) {
        return;
      }

      // Map sanitized name back to original name (with dots)
      const toolName = session.toolNameMap.get(sanitizedName) ?? sanitizedName;

      // Store tool use data — execution happens on contentEnd with type "TOOL"
      this.cancelPendingAssistantTurnFinalize(session);
      session.pendingToolUse = { toolName, toolUseId, content };
      return;
    }

    if ("contentEnd" in event) {
      const payload = asRecord(event.contentEnd);
      const contentId = payload ? (asString(payload.contentId) ?? asString(payload.contentName)) : undefined;
      const contentType = payload ? asString(payload.type) : undefined;

      // Handle tool use completion — execute the pending tool call
      if (contentType === "TOOL" && asString(payload?.stopReason) === "TOOL_USE" && session.pendingToolUse) {
        this.cancelPendingAssistantTurnFinalize(session);
        const pending = session.pendingToolUse;
        session.pendingToolUse = null;

        let input: Record<string, unknown> = {};
        try {
          const parsedInput = JSON.parse(pending.content) as unknown;
          if (parsedInput && typeof parsedInput === "object" && !Array.isArray(parsedInput)) {
            input = parsedInput as Record<string, unknown>;
          }
        } catch {
          input = {};
        }

        void this.handleToolUse(session, {
          id: pending.toolUseId,
          name: pending.toolName,
          input,
        });
        // Also clean up the content entry if it exists
        if (contentId) {
          session.contents.delete(contentId);
        }
        return;
      }

      if (!contentId) {
        return;
      }
      const info = session.contents.get(contentId);
      session.contents.delete(contentId);
      if (!info) {
        return;
      }

      if (info.role === "USER" && info.type === "TEXT" && info.text.trim().length > 0) {
        // Finalize any pending assistant text before emitting the user message,
        // so the iOS partial-replacement logic sees isPartial:false before the user message.
        this.finishAssistantTurn(session, {
          emitIdle: false,
          reason: "user_turn_flush",
        });

        session.context.emit(makeEvent("user.audio.transcript.final", session.sessionId, {
          text: info.text.trim(),
        }));
        session.context.emit(makeEvent("tool.call", session.sessionId, {
          callId: crypto.randomUUID(),
          name: "convo.appendMessage",
          arguments: JSON.stringify({
            role: "user",
            text: info.text.trim(),
            isPartial: false,
          }),
        }));
        session.context.emit(makeEvent("tool.call", session.sessionId, {
          callId: crypto.randomUUID(),
          name: "convo.setState",
          arguments: JSON.stringify({ state: "thinking" }),
        }));
      }

      if (info.role === "ASSISTANT" && info.type === "TEXT" && info.generationStage === "SPECULATIVE" && info.text.trim().length > 0 && !session.bargedIn) {
        const text = info.text.trim();

        // Skip Nova Sonic metadata responses (same guard as FINAL)
        if (text.startsWith("{") && text.endsWith("}")) {
          try { JSON.parse(text); return; } catch { /* treat as speech */ }
        }

        // Preview = confirmed text so far + speculative upcoming text
        const previewText = session.accumulatedAssistantText
          ? session.accumulatedAssistantText + " " + text
          : text;

        // Create/update the grey transcript bubble BEFORE audio plays
        session.context.emit(makeEvent("tool.call", session.sessionId, {
          callId: crypto.randomUUID(),
          name: "convo.appendMessage",
          arguments: JSON.stringify({
            role: "assistant",
            text: previewText,
            isPartial: true,
            liveResponseId: this.ensureLiveResponseId(session),
          }),
        }));
      }

      if (info.role === "ASSISTANT" && info.type === "TEXT" && info.generationStage === "FINAL" && info.text.trim().length > 0 && !session.bargedIn) {
        const text = info.text.trim();

        // Skip Nova Sonic metadata responses (e.g., { "interrupted" : true })
        if (text.startsWith("{") && text.endsWith("}")) {
          try {
            JSON.parse(text);
            return;
          } catch {
            // Not valid JSON — treat as speech
          }
        }

        // Accumulate sentences — the full message is only finalized when audio ends.
        session.accumulatedAssistantText = session.accumulatedAssistantText
          ? session.accumulatedAssistantText + " " + text
          : text;

        // Emit a growing partial message so the UI shows one expanding bubble.
        session.context.emit(makeEvent("tool.call", session.sessionId, {
          callId: crypto.randomUUID(),
          name: "convo.appendMessage",
          arguments: JSON.stringify({
            role: "assistant",
            text: session.accumulatedAssistantText,
            isPartial: true,
            liveResponseId: this.ensureLiveResponseId(session),
          }),
        }));
      }

      if (info.role === "ASSISTANT" && info.type === "AUDIO" && !session.bargedIn) {
        session.context.emit(makeEvent("assistant.audio.end", session.sessionId, {
          ...(session.liveResponseId ? { liveResponseId: session.liveResponseId } : {}),
        }));
        session.sawAssistantAudio = true;
        this.scheduleAssistantTurnFinalize(session);
      }
      return;
    }

    if ("completionEnd" in event) {
      const payload = asRecord(event.completionEnd);
      const stopReason = payload ? asString(payload.stopReason) : undefined;
      if (stopReason === "INTERRUPTED" || stopReason === "BARGE_IN") {
        this.handleBargeIn(session, stopReason.toLowerCase());
        session.bargedIn = false;
        return;
      }

      if (stopReason === "END_TURN") {
        session.bargedIn = false;
        this.finishAssistantTurn(session, {
          emitIdle: true,
          reason: "completion_end",
        });
      }
    }
  }

  private ensureLiveResponseId(session: SonicSession): string {
    if (!session.liveResponseId) {
      session.liveResponseId = crypto.randomUUID();
    }
    return session.liveResponseId;
  }

  private deleteSessionIfCurrent(session: SonicSession): void {
    if (this.sessions.get(session.sessionId) === session) {
      this.sessions.delete(session.sessionId);
    }
  }

  private resetAssistantTurnState(session: SonicSession): string | null {
    const liveResponseId = session.liveResponseId;
    this.cancelPendingAssistantTurnFinalize(session);
    session.sawAssistantAudio = false;
    session.pendingToolUse = null;
    session.toolExecutionInFlight = false;
    session.contents.clear();
    session.accumulatedAssistantText = "";
    session.liveResponseId = null;
    return liveResponseId;
  }

  private closeTransport(
    outgoing: AsyncPushQueue<InvokeModelWithBidirectionalStreamInput>,
    promptName: string,
    audioContentName: string,
  ): void {
    const sendTransportEvent = (event: Record<string, unknown>) => {
      const payload = this.encoder.encode(JSON.stringify({ event }));
      outgoing.push({
        chunk: {
          bytes: payload,
        },
      });
    };

    sendTransportEvent({
      contentEnd: {
        promptName,
        contentName: audioContentName,
      },
    });
    sendTransportEvent({
      promptEnd: {
        promptName,
      },
    });
    sendTransportEvent({
      sessionEnd: {},
    });
    outgoing.close();
  }

  private handleBargeIn(session: SonicSession, reason: string): void {
    if (session.closed || session.bargedIn) return;

    const liveResponseId = this.resetAssistantTurnState(session);
    session.bargedIn = true;

    if (liveResponseId) {
      session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
        reason,
        liveResponseId,
      }));
    }
    this.emitListeningState(session);
  }

  private async restartSessionAfterError(
    session: SonicSession,
    interruptionReason: string,
  ): Promise<void> {
    if (session.closed || session.restarting) {
      return;
    }

    const liveResponseId = this.resetAssistantTurnState(session);
    const previousOutgoing = session.outgoing;
    const previousPromptName = session.promptName;
    const previousAudioContentName = session.audioContentName;

    session.restarting = true;
    session.streamGeneration += 1;

    if (liveResponseId) {
      session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
        reason: interruptionReason,
        liveResponseId,
      }));
    }
    this.emitListeningState(session);

    this.closeTransport(previousOutgoing, previousPromptName, previousAudioContentName);

    try {
      await this.openModelStream(session);
    } catch (error) {
      session.restarting = false;
      const message = error instanceof Error ? error.message : JSON.stringify(error, null, 2);
      await this.handleSessionFailure(session, message);
    }
  }

  private beginSessionShutdown(
    session: SonicSession,
    options: {
      interruptionReason?: string;
      recoverToListening?: boolean;
      failureMessage?: string;
    } = {},
  ): void {
    if (session.closed) {
      return;
    }

    session.closed = true;
    session.restarting = false;
    const liveResponseId = this.resetAssistantTurnState(session);
    this.deleteSessionIfCurrent(session);

    if (options.interruptionReason && liveResponseId) {
      session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
        reason: options.interruptionReason,
        liveResponseId,
      }));
    }

    if (options.failureMessage) {
      session.context.emit(makeEvent("error", session.sessionId, {
        code: "voice_provider_failed",
        message: options.failureMessage,
      }));
    }

    if (options.recoverToListening) {
      session.context.emit(makeEvent("tool.call", session.sessionId, {
        callId: crypto.randomUUID(),
        name: "convo.setState",
        arguments: JSON.stringify({ state: "listening" }),
      }));
    }

    this.closeTransport(session.outgoing, session.promptName, session.audioContentName);
  }

  private async handleSessionFailure(session: SonicSession, message: string): Promise<void> {
    if (session.closed) {
      return;
    }
    this.beginSessionShutdown(session, {
      failureMessage: message,
      recoverToListening: true,
    });
  }

  private async handleToolUse(session: SonicSession, toolCall: ToolCallRequest): Promise<void> {
    if (!session.context.executeTool) {
      return;
    }

    // Circuit breaker: if the same tool has failed too many times in a row,
    // return a hard stop error instead of executing again.
    const MAX_CONSECUTIVE_FAILURES = 3;
    const priorFailures = session.toolFailureCounts.get(toolCall.name) ?? 0;
    if (priorFailures >= MAX_CONSECUTIVE_FAILURES) {
      logger.warn(
        `circuit breaker: ${toolCall.name} failed ${priorFailures} times consecutively, refusing to retry`,
        { sessionId: session.sessionId },
      );
      this.sendToolResult(session, toolCall.id, JSON.stringify({
        error: `${toolCall.name} has failed ${priorFailures} times in a row. Do NOT retry this tool. Tell the user what went wrong and ask how they would like to proceed.`,
      }));
      return;
    }

    session.toolExecutionInFlight = true;
    try {
      const result = await session.context.executeTool(session.sessionId, toolCall, session.context.emit);
      if (session.closed) {
        return;
      }

      // Track consecutive failures per tool for circuit breaking.
      if (result.error) {
        session.toolFailureCounts.set(toolCall.name, priorFailures + 1);
      } else {
        session.toolFailureCounts.delete(toolCall.name);
      }

      this.sendToolResult(session, toolCall.id, result.error
        ? JSON.stringify({ error: result.error })
        : (result.result ?? "{}"));
    } finally {
      session.toolExecutionInFlight = false;
    }
  }

  private sendToolResult(session: SonicSession, toolUseId: string, content: string): void {
    const contentName = `tool-${crypto.randomUUID()}`;
    this.sendEvent(session, {
      contentStart: {
        promptName: session.promptName,
        contentName,
        interactive: false,
        type: "TOOL",
        role: "TOOL",
        toolResultInputConfiguration: {
          toolUseId,
          type: "TEXT",
          textInputConfiguration: {
            mediaType: "text/plain",
          },
        },
      },
    });
    this.sendEvent(session, {
      toolResult: {
        promptName: session.promptName,
        contentName,
        content,
      },
    });
    this.sendEvent(session, {
      contentEnd: {
        promptName: session.promptName,
        contentName,
      },
    });
  }

  private sendEvent(session: SonicSession, event: Record<string, unknown>): void {
    const payload = this.encoder.encode(JSON.stringify({ event }));
    session.outgoing.push({
      chunk: {
        bytes: payload,
      },
    });
  }

  private tryParseEnvelope(raw: string): SonicEventEnvelope | null {
    try {
      return JSON.parse(raw) as SonicEventEnvelope;
    } catch {
      logger.warn("failed to parse sonic output chunk", { trace: raw.slice(0, 120) });
      return null;
    }
  }
}

class AsyncPushQueue<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private resolvers: Array<(result: IteratorResult<T>) => void> = [];
  private isClosed = false;

  push(item: T): void {
    if (this.isClosed) {
      return;
    }
    const resolver = this.resolvers.shift();
    if (resolver) {
      resolver({ value: item, done: false });
      return;
    }
    this.items.push(item);
  }

  close(): void {
    if (this.isClosed) {
      return;
    }
    this.isClosed = true;
    while (this.resolvers.length > 0) {
      const resolver = this.resolvers.shift();
      resolver?.({ value: undefined as T, done: true });
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: async () => {
        if (this.items.length > 0) {
          const value = this.items.shift() as T;
          return { value, done: false };
        }
        if (this.isClosed) {
          return { value: undefined as T, done: true };
        }
        return new Promise<IteratorResult<T>>((resolve) => {
          this.resolvers.push(resolve);
        });
      },
    };
  }
}

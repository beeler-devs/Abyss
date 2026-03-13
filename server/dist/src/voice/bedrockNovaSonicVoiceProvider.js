import crypto from "node:crypto";
import { BedrockRuntimeClient, InvokeModelWithBidirectionalStreamCommand, } from "@aws-sdk/client-bedrock-runtime";
import { makeEvent } from "../core/events.js";
import { logger } from "../core/logger.js";
function asRecord(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        return null;
    }
    return value;
}
function asString(value) {
    return typeof value === "string" ? value : undefined;
}
function parseAdditionalModelFields(value) {
    if (typeof value !== "string" || value.trim().length === 0) {
        return {};
    }
    try {
        const parsed = JSON.parse(value);
        return asRecord(parsed) ?? {};
    }
    catch {
        return {};
    }
}
export class BedrockNovaSonicVoiceProvider {
    name = "nova-sonic";
    config;
    client;
    sessions = new Map();
    encoder = new TextEncoder();
    decoder = new TextDecoder();
    constructor(config, client) {
        this.config = config;
        this.client = client ?? new BedrockRuntimeClient({ region: config.region });
    }
    async startStream(sessionId, context) {
        if (this.sessions.has(sessionId)) {
            return;
        }
        const outgoing = new AsyncPushQueue();
        const promptName = `prompt-${crypto.randomUUID()}`;
        const audioContentName = `audio-${crypto.randomUUID()}`;
        const session = {
            sessionId,
            promptName,
            audioContentName,
            outgoing,
            context,
            responseTask: Promise.resolve(),
            closed: false,
            sawAssistantAudio: false,
            contents: new Map(),
        };
        this.sessions.set(sessionId, session);
        const response = await this.client.send(new InvokeModelWithBidirectionalStreamCommand({
            modelId: this.config.modelId,
            body: outgoing,
        }));
        session.responseTask = this.consumeResponseStream(session, response.body);
        this.sendEvent(session, {
            sessionStart: {
                inferenceConfiguration: {
                    maxTokens: 1024,
                    temperature: 0.3,
                    topP: 0.9,
                },
                turnDetectionConfiguration: {
                    endOfSpeechSensitivity: "MEDIUM",
                },
            },
        });
        this.sendEvent(session, {
            promptStart: {
                promptName,
                textOutputConfiguration: {
                    mediaType: "text/plain",
                },
                audioOutputConfiguration: {
                    mediaType: "audio/lpcm",
                    sampleRateHertz: 16000,
                    sampleSizeBits: 16,
                    channelCount: 1,
                    voiceId: this.config.voiceId,
                },
            },
        });
        const systemContentName = `system-${crypto.randomUUID()}`;
        this.sendEvent(session, {
            contentStart: {
                promptName,
                contentName: systemContentName,
                type: "SYSTEM",
                role: "SYSTEM",
            },
        });
        this.sendEvent(session, {
            textInput: {
                promptName,
                contentName: systemContentName,
                content: "You are the Abyss voice-first coding assistant. Keep responses concise, practical, and voice-friendly.",
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
                role: "USER",
                audioInputConfiguration: {
                    mediaType: "audio/lpcm",
                    sampleRateHertz: 16000,
                    sampleSizeBits: 16,
                    channelCount: 1,
                },
            },
        });
        context.emit(makeEvent("tool.call", sessionId, {
            callId: crypto.randomUUID(),
            name: "convo.setState",
            arguments: JSON.stringify({ state: "listening" }),
        }));
    }
    async appendAudioChunk(sessionId, base64Audio) {
        const session = this.sessions.get(sessionId);
        if (!session || session.closed || !base64Audio) {
            return;
        }
        this.sendEvent(session, {
            audioInput: {
                promptName: session.promptName,
                contentName: session.audioContentName,
                content: base64Audio,
            },
        });
    }
    async endStream(_sessionId) {
        // Nova Sonic handles endpointing server-side. Keep the audio content stream open
        // for the duration of the conversation so subsequent turns can reuse the same session.
    }
    async interrupt(sessionId) {
        const session = this.sessions.get(sessionId);
        if (!session) {
            return;
        }
        session.context.emit(makeEvent("assistant.audio.interrupted", sessionId, {
            reason: "user_interrupt",
        }));
        session.context.emit(makeEvent("tool.call", sessionId, {
            callId: crypto.randomUUID(),
            name: "convo.setState",
            arguments: JSON.stringify({ state: "listening" }),
        }));
    }
    async closeSession(sessionId) {
        const session = this.sessions.get(sessionId);
        if (!session || session.closed) {
            return;
        }
        session.closed = true;
        this.sendEvent(session, {
            contentEnd: {
                promptName: session.promptName,
                contentName: session.audioContentName,
            },
        });
        this.sendEvent(session, {
            promptEnd: {
                promptName: session.promptName,
            },
        });
        this.sendEvent(session, {
            sessionEnd: {},
        });
        session.outgoing.close();
        try {
            await session.responseTask;
        }
        finally {
            this.sessions.delete(sessionId);
        }
    }
    async consumeResponseStream(session, body) {
        if (!body) {
            return;
        }
        try {
            for await (const frame of body) {
                if ("chunk" in frame && frame.chunk?.bytes) {
                    const raw = this.decoder.decode(frame.chunk.bytes);
                    this.handleOutputEvent(session, raw);
                    continue;
                }
                const errorFrame = (("internalServerException" in frame && frame.internalServerException?.message)
                    || ("modelStreamErrorException" in frame && frame.modelStreamErrorException?.message)
                    || ("validationException" in frame && frame.validationException?.message)
                    || ("throttlingException" in frame && frame.throttlingException?.message)
                    || ("modelTimeoutException" in frame && frame.modelTimeoutException?.message)
                    || ("serviceUnavailableException" in frame && frame.serviceUnavailableException?.message));
                if (errorFrame) {
                    session.context.emit(makeEvent("error", session.sessionId, {
                        code: "voice_provider_failed",
                        message: String(errorFrame),
                    }));
                }
            }
        }
        catch (error) {
            const message = error instanceof Error ? error.message : "Unknown voice provider error";
            logger.error(`voice provider failed: ${message}`, { sessionId: session.sessionId });
            session.context.emit(makeEvent("error", session.sessionId, {
                code: "voice_provider_failed",
                message,
            }));
        }
    }
    handleOutputEvent(session, raw) {
        const parsed = this.tryParseEnvelope(raw);
        if (!parsed?.event) {
            return;
        }
        const event = parsed.event;
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
            info.text += content;
            if (info.role === "ASSISTANT" && info.generationStage === "SPECULATIVE") {
                session.context.emit(makeEvent("assistant.speech.partial", session.sessionId, {
                    text: info.text,
                }));
            }
            return;
        }
        if ("audioOutput" in event) {
            const payload = asRecord(event.audioOutput);
            const audio = payload ? (asString(payload.content) ?? asString(payload.bytes)) : undefined;
            if (!audio) {
                return;
            }
            session.sawAssistantAudio = true;
            session.context.emit(makeEvent("tool.call", session.sessionId, {
                callId: crypto.randomUUID(),
                name: "convo.setState",
                arguments: JSON.stringify({ state: "speaking" }),
            }));
            session.context.emit(makeEvent("assistant.audio.chunk", session.sessionId, {
                audio,
                encoding: "pcm_s16le",
                sampleRateHertz: 16000,
                channelCount: 1,
            }));
            return;
        }
        if ("toolUse" in event) {
            const payload = asRecord(event.toolUse);
            if (!payload || !session.context.executeTool) {
                return;
            }
            const toolName = asString(payload.toolName) ?? asString(payload.name);
            const toolUseId = asString(payload.toolUseId);
            const content = asString(payload.content) ?? "{}";
            if (!toolName || !toolUseId) {
                return;
            }
            let input = {};
            try {
                const parsedInput = JSON.parse(content);
                if (parsedInput && typeof parsedInput === "object" && !Array.isArray(parsedInput)) {
                    input = parsedInput;
                }
            }
            catch {
                input = {};
            }
            void this.handleToolUse(session, {
                id: toolUseId,
                name: toolName,
                input,
            });
            return;
        }
        if ("contentEnd" in event) {
            const payload = asRecord(event.contentEnd);
            const contentId = payload ? (asString(payload.contentId) ?? asString(payload.contentName)) : undefined;
            if (!contentId) {
                return;
            }
            const info = session.contents.get(contentId);
            session.contents.delete(contentId);
            if (!info) {
                return;
            }
            if (info.role === "USER" && info.type === "TEXT" && info.text.trim().length > 0) {
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
            if (info.role === "ASSISTANT" && info.type === "TEXT" && info.generationStage === "FINAL" && info.text.trim().length > 0) {
                const text = info.text.trim();
                session.context.emit(makeEvent("assistant.speech.final", session.sessionId, { text }));
                session.context.emit(makeEvent("tool.call", session.sessionId, {
                    callId: crypto.randomUUID(),
                    name: "convo.appendMessage",
                    arguments: JSON.stringify({
                        role: "assistant",
                        text,
                        isPartial: false,
                    }),
                }));
            }
            if (info.role === "ASSISTANT" && info.type === "AUDIO") {
                session.context.emit(makeEvent("assistant.audio.end", session.sessionId, {}));
                session.context.emit(makeEvent("tool.call", session.sessionId, {
                    callId: crypto.randomUUID(),
                    name: "convo.setState",
                    arguments: JSON.stringify({ state: "idle" }),
                }));
                session.sawAssistantAudio = false;
            }
            return;
        }
        if ("completionEnd" in event) {
            const payload = asRecord(event.completionEnd);
            const stopReason = payload ? asString(payload.stopReason) : undefined;
            if (stopReason === "INTERRUPTED" || stopReason === "BARGE_IN") {
                session.context.emit(makeEvent("assistant.audio.interrupted", session.sessionId, {
                    reason: stopReason.toLowerCase(),
                }));
                session.context.emit(makeEvent("tool.call", session.sessionId, {
                    callId: crypto.randomUUID(),
                    name: "convo.setState",
                    arguments: JSON.stringify({ state: "listening" }),
                }));
            }
        }
    }
    async handleToolUse(session, toolCall) {
        if (!session.context.executeTool) {
            return;
        }
        const result = await session.context.executeTool(session.sessionId, toolCall, session.context.emit);
        const contentName = `tool-${crypto.randomUUID()}`;
        this.sendEvent(session, {
            contentStart: {
                promptName: session.promptName,
                contentName,
                type: "TOOL",
                role: "TOOL",
                toolResultInputConfiguration: {
                    toolUseId: toolCall.id,
                    type: "TEXT",
                },
            },
        });
        this.sendEvent(session, {
            textInput: {
                promptName: session.promptName,
                contentName,
                content: result.error
                    ? JSON.stringify({ error: result.error })
                    : (result.result ?? "{}"),
            },
        });
        this.sendEvent(session, {
            contentEnd: {
                promptName: session.promptName,
                contentName,
            },
        });
    }
    sendEvent(session, event) {
        const payload = this.encoder.encode(JSON.stringify({ event }));
        session.outgoing.push({
            chunk: {
                bytes: payload,
            },
        });
    }
    tryParseEnvelope(raw) {
        try {
            return JSON.parse(raw);
        }
        catch {
            logger.warn("failed to parse sonic output chunk", { trace: raw.slice(0, 120) });
            return null;
        }
    }
}
class AsyncPushQueue {
    items = [];
    resolvers = [];
    isClosed = false;
    push(item) {
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
    close() {
        if (this.isClosed) {
            return;
        }
        this.isClosed = true;
        while (this.resolvers.length > 0) {
            const resolver = this.resolvers.shift();
            resolver?.({ value: undefined, done: true });
        }
    }
    [Symbol.asyncIterator]() {
        return {
            next: async () => {
                if (this.items.length > 0) {
                    const value = this.items.shift();
                    return { value, done: false };
                }
                if (this.isClosed) {
                    return { value: undefined, done: true };
                }
                return new Promise((resolve) => {
                    this.resolvers.push(resolve);
                });
            },
        };
    }
}

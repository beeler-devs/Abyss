import crypto from "node:crypto";
import { BedrockRuntimeClient, InvokeModelWithBidirectionalStreamCommand, } from "@aws-sdk/client-bedrock-runtime";
import { NodeHttp2Handler } from "@smithy/node-http-handler";
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
const VOICE_PIPELINE_TOOL_PREFIXES = ["stt.", "tts.", "convo."];
/** Sanitize tool name for Nova Sonic — only [a-zA-Z0-9_] allowed. */
function sanitizeToolName(name) {
    return name.replace(/[^a-zA-Z0-9_]/g, "_");
}
function convertToolsForSonic(tools) {
    const eligible = tools.filter((t) => !VOICE_PIPELINE_TOOL_PREFIXES.some((prefix) => t.name.startsWith(prefix)));
    if (eligible.length === 0) {
        return undefined;
    }
    const nameMap = new Map();
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
export class BedrockNovaSonicVoiceProvider {
    name = "nova-sonic";
    config;
    client;
    sessions = new Map();
    encoder = new TextEncoder();
    decoder = new TextDecoder();
    constructor(config, client) {
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
    }
    async startStream(sessionId, context) {
        const existing = this.sessions.get(sessionId);
        if (existing) {
            // Session already open — audio content stream stays open across turns.
            existing.context.emit(makeEvent("tool.call", sessionId, {
                callId: crypto.randomUUID(),
                name: "convo.setState",
                arguments: JSON.stringify({ state: "listening" }),
            }));
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
            pendingToolUse: null,
            toolNameMap: new Map(),
            accumulatedAssistantText: "",
        };
        this.sessions.set(sessionId, session);
        const rawTools = context.listTools(sessionId);
        const toolResult = this.config.enableTools !== false
            ? convertToolsForSonic(rawTools)
            : undefined;
        const toolConfiguration = toolResult?.config;
        const toolCount = toolConfiguration
            ? toolConfiguration.tools.length
            : 0;
        if (toolResult) {
            session.toolNameMap = toolResult.nameMap;
        }
        logger.info(`tools configured: ${toolCount} (enableTools=${this.config.enableTools})`, { sessionId });
        if (toolCount > 0) {
            logger.info(`tool names: ${[...session.toolNameMap.keys()].join(", ")}`, { sessionId });
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
        const promptStartPayload = {
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
        session.responseTask = this.consumeResponseStream(session, response.body);
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
        // No-op — the client sends trailing silence before the end event to
        // trigger Nova Sonic's server-side VAD. The audio content stream stays
        // open for the duration of the session.
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
            const message = error instanceof Error ? error.message : JSON.stringify(error, null, 2);
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
                const preview = session.accumulatedAssistantText
                    ? session.accumulatedAssistantText + " " + info.text
                    : info.text;
                session.context.emit(makeEvent("assistant.speech.partial", session.sessionId, {
                    text: preview,
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
            if (!session.sawAssistantAudio) {
                session.sawAssistantAudio = true;
                session.context.emit(makeEvent("tool.call", session.sessionId, {
                    callId: crypto.randomUUID(),
                    name: "convo.setState",
                    arguments: JSON.stringify({ state: "speaking" }),
                }));
            }
            session.context.emit(makeEvent("assistant.audio.chunk", session.sessionId, {
                audio,
                encoding: "pcm_s16le",
                sampleRateHertz: 24000,
                channelCount: 1,
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
            session.pendingToolUse = { toolName, toolUseId, content };
            return;
        }
        if ("contentEnd" in event) {
            const payload = asRecord(event.contentEnd);
            const contentId = payload ? (asString(payload.contentId) ?? asString(payload.contentName)) : undefined;
            const contentType = payload ? asString(payload.type) : undefined;
            // Handle tool use completion — execute the pending tool call
            if (contentType === "TOOL" && asString(payload?.stopReason) === "TOOL_USE" && session.pendingToolUse) {
                const pending = session.pendingToolUse;
                session.pendingToolUse = null;
                let input = {};
                try {
                    const parsedInput = JSON.parse(pending.content);
                    if (parsedInput && typeof parsedInput === "object" && !Array.isArray(parsedInput)) {
                        input = parsedInput;
                    }
                }
                catch {
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
                // Skip Nova Sonic metadata responses (e.g., { "interrupted" : true })
                if (text.startsWith("{") && text.endsWith("}")) {
                    try {
                        JSON.parse(text);
                        return;
                    }
                    catch {
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
                    }),
                }));
            }
            if (info.role === "ASSISTANT" && info.type === "AUDIO") {
                session.context.emit(makeEvent("assistant.audio.end", session.sessionId, {}));
                // Finalize the accumulated message as a single non-partial bubble.
                if (session.accumulatedAssistantText) {
                    session.context.emit(makeEvent("assistant.speech.final", session.sessionId, {
                        text: session.accumulatedAssistantText,
                    }));
                    session.context.emit(makeEvent("tool.call", session.sessionId, {
                        callId: crypto.randomUUID(),
                        name: "convo.appendMessage",
                        arguments: JSON.stringify({
                            role: "assistant",
                            text: session.accumulatedAssistantText,
                            isPartial: false,
                        }),
                    }));
                    session.accumulatedAssistantText = "";
                }
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
                session.accumulatedAssistantText = "";
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
                interactive: false,
                type: "TOOL",
                role: "TOOL",
                toolResultInputConfiguration: {
                    toolUseId: toolCall.id,
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

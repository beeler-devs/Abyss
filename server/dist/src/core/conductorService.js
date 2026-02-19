import crypto from "node:crypto";
import { asString, makeEvent } from "./events.js";
import { logger } from "./logger.js";
import { SessionStore } from "./sessionStore.js";
const AGENT_TOOLS = [
    {
        name: "agent.spawn",
        description: "Launch a new Cursor Cloud Agent to work on a repository. Use for coding tasks, PR creation, analysis. Requires a prompt and either repository (format: owner/repo) or prUrl.",
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
        description: "List all GitHub repositories the user has connected to Cursor. Call this before agent.spawn when you do not know the exact owner/repo string, or when the user refers to a repo by name. Returns a list of {repository, owner, name} objects. Always prefer a repository from this list over guessing.",
        input_schema: {
            type: "object",
            properties: {},
        },
    },
];
function waitForToolResult(session, callId, timeoutMs) {
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
    provider;
    sessions;
    constructor(provider, config) {
        this.provider = provider;
        this.sessions = new SessionStore(config.maxTurns, config.rateLimitPerMinute);
    }
    createRateLimiter() {
        return this.sessions.createRateLimiter();
    }
    async handleEvent(event, emit) {
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
                    logger.info(errorText ? `tool.result error: ${errorText}` : "tool.result ok", {
                        sessionId: session.sessionId,
                        eventId: event.id,
                        callId,
                        trace: pending?.toolName,
                    });
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
                    `Tell the user what the agent accomplished (or what went wrong if it failed),`,
                    `in a concise, natural sentence or two. Do not repeat the raw summary verbatim.`,
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
    async runConductorLoop(session, transcript, emit, sourceEventId, options = {}) {
        session.transcriptCount += 1;
        session.recentTranscriptTrace = [];
        const tracePush = (value) => {
            session.recentTranscriptTrace.push(value);
            this.sessions.recordTrace(session, value);
        };
        const emitToolCall = (toolName, args) => {
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
        while (toolRound < MAX_TOOL_ROUNDS) {
            toolRound += 1;
            let modelResponse;
            try {
                modelResponse = await this.provider.generateResponse(session.history, AGENT_TOOLS);
            }
            catch (error) {
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
            if (modelResponse.toolCalls && modelResponse.toolCalls.length > 0) {
                this.sessions.appendTurn(session, {
                    role: "assistant",
                    content: modelResponse.toolCalls,
                });
                for (const toolCall of modelResponse.toolCalls) {
                    const callId = crypto.randomUUID();
                    const envelope = makeEvent("tool.call", session.sessionId, {
                        callId,
                        name: toolCall.name,
                        arguments: JSON.stringify(toolCall.input),
                    });
                    session.pendingToolCalls.set(callId, {
                        callId,
                        toolName: toolCall.name,
                        emittedAt: envelope.timestamp,
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
        logger.info(`${traceLabel}: ${session.recentTranscriptTrace.join(" -> ")}`, { sessionId: session.sessionId, eventId: sourceEventId });
    }
}

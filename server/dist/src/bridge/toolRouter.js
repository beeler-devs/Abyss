import crypto from "node:crypto";
import { makeEvent } from "../core/events.js";
import { logger } from "../core/logger.js";
import { optionalString, summarizeValueForLog } from "../core/utils.js";
export class BridgeToolRouter {
    state;
    sendToBridge;
    emitToIOS;
    pendingByCallId = new Map();
    pendingRunsByCommandId = new Map();
    activeCommandBySession = new Map();
    narrationByCommandId = new Map();
    // stream-json parsing for bridge.claude.run
    activeClaudeRunsByDeviceId = new Map();
    activeClaudeRunByCommandId = new Map();
    activeClaudeCommandIdByDeviceId = new Map(); // deviceId → commandId
    claudeLineBuffers = new Map(); // commandId → partial line
    lastClaudeProgressAt = new Map(); // commandId → ms
    claudeExitCodeByCommandId = new Map();
    verboseToolRoutingLogs;
    constructor(deps) {
        this.state = deps.state;
        this.sendToBridge = deps.sendToBridge;
        this.emitToIOS = deps.emitToIOS;
        this.verboseToolRoutingLogs = deps.verboseToolRoutingLogs ?? false;
    }
    async execute(request) {
        const requestedDeviceId = optionalString(request.args.deviceId);
        const resolved = this.state.resolveDeviceForTool(request.sessionId, requestedDeviceId);
        if (!resolved.device) {
            if (resolved.selectionRequired?.length) {
                this.emitToIOS(makeEvent("bridge.device.selection.required", request.sessionId, {
                    devices: resolved.selectionRequired,
                }));
            }
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error: resolved.error ?? "bridge_routing_failed",
            }));
            return { result: null, error: resolved.error ?? "bridge_routing_failed" };
        }
        if (request.toolName !== "bridge.claude.run"
            && request.toolName !== "bridge.exec.cancel"
            && this.activeClaudeRunsByDeviceId.has(resolved.device.deviceId)) {
            const error = "bridge device is busy running Claude Code. Wait for that task to finish before starting another bridge command.";
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error,
            }));
            return { result: null, error };
        }
        // Keep iOS timeline visibility for every bridge tool call.
        this.emitToIOS(makeEvent("tool.call", request.sessionId, {
            callId: request.callId,
            name: request.toolName,
            arguments: JSON.stringify(request.args),
        }));
        if (request.toolName === "bridge.exec.run") {
            return await this.executeLegacyRun(request, resolved.device);
        }
        if (request.toolName === "bridge.claude.run") {
            return await this.executeClaudeRun(request, resolved.device.deviceId);
        }
        return await this.invokeBridgeTool({
            callId: request.callId,
            resultCallId: request.callId,
            sessionId: request.sessionId,
            deviceId: resolved.device.deviceId,
            toolName: request.toolName,
            args: request.args,
            timeoutMs: request.timeoutMs,
            emitResultToIOS: true,
        });
    }
    handleBridgeEvent(event, bridgeDeviceId) {
        switch (event.type) {
            case "tool.result":
                return this.handleBridgeToolResult(event);
            case "bridge.exec.output":
                return this.forwardExecOutput(event, bridgeDeviceId);
            case "bridge.exec.finished":
                return this.forwardExecFinished(event, bridgeDeviceId);
            default:
                return false;
        }
    }
    async cancelActiveCommand(sessionId) {
        const active = this.activeCommandBySession.get(sessionId);
        if (!active) {
            return false;
        }
        const cancelCallId = `bridge-cancel-${crypto.randomUUID()}`;
        const result = await this.invokeBridgeTool({
            callId: cancelCallId,
            resultCallId: cancelCallId,
            sessionId,
            deviceId: active.deviceId,
            toolName: "bridge.exec.cancel",
            args: { commandId: active.commandId },
            timeoutMs: 5_000,
            emitResultToIOS: false,
        });
        return !result.error;
    }
    failPendingForDevice(deviceId) {
        const pendingCalls = [...this.pendingByCallId.values()].filter((pending) => pending.deviceId === deviceId);
        for (const pending of pendingCalls) {
            this.pendingByCallId.delete(pending.callId);
            clearTimeout(pending.timer);
            const error = "bridge_device_disconnected";
            if (pending.emitResultToIOS) {
                this.emitToIOS(makeEvent("tool.result", pending.sessionId, {
                    callId: pending.resultCallId,
                    result: null,
                    error,
                }));
            }
            pending.resolve({ result: null, error });
        }
        for (const [commandId, waiters] of this.pendingRunsByCommandId.entries()) {
            const matched = waiters.filter((waiter) => waiter.deviceId === deviceId);
            if (matched.length === 0) {
                continue;
            }
            const remaining = waiters.filter((waiter) => waiter.deviceId !== deviceId);
            if (remaining.length) {
                this.pendingRunsByCommandId.set(commandId, remaining);
            }
            else {
                this.pendingRunsByCommandId.delete(commandId);
            }
            for (const waiter of matched) {
                clearTimeout(waiter.timer);
                const error = "bridge_device_disconnected";
                this.emitToIOS(makeEvent("tool.result", waiter.sessionId, {
                    callId: waiter.toolCallId,
                    result: null,
                    error,
                }));
                waiter.resolve({ result: null, error });
            }
        }
        for (const [sessionId, active] of this.activeCommandBySession.entries()) {
            if (active.deviceId === deviceId) {
                this.activeCommandBySession.delete(sessionId);
            }
        }
        for (const [commandId, narration] of this.narrationByCommandId.entries()) {
            if (narration.deviceId === deviceId) {
                this.narrationByCommandId.delete(commandId);
            }
        }
        this.cleanupClaudeRun(deviceId);
    }
    async executeClaudeRun(request, deviceId) {
        if (this.activeClaudeRunsByDeviceId.has(deviceId)) {
            const error = "bridge.claude.run already active on this device. Wait for it to finish before starting another Claude Code task.";
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error,
            }));
            return { result: null, error };
        }
        const startedAtMs = Date.now();
        this.activeClaudeRunsByDeviceId.set(deviceId, {
            sessionId: request.sessionId,
            callId: request.callId,
            startedAtMs,
            timeoutMs: request.timeoutMs,
        });
        const promptPreview = this.verboseToolRoutingLogs
            ? ` prompt=${summarizeValueForLog(request.args.prompt) ?? "<empty>"}`
            : "";
        logger.info(`bridge.claude.run.start timeoutMs=${request.timeoutMs}${promptPreview}`, {
            sessionId: request.sessionId,
            deviceId,
            callId: request.callId,
        });
        this.emitAssistantSpeechToolCall(request.sessionId, "Running Claude Code on your Mac. This may take a few minutes.");
        this.emitAssistantProgress(request.sessionId, "Claude Code is running…", true);
        let minuteCount = 1;
        const progressInterval = setInterval(() => {
            this.emitAssistantSpeechToolCall(request.sessionId, minuteCount === 1 ? "Still working on it. Hang tight." : "Claude Code is still running.");
            minuteCount += 1;
        }, 60_000);
        let finishError = null;
        try {
            const result = await this.invokeBridgeTool({
                callId: request.callId,
                resultCallId: request.callId,
                sessionId: request.sessionId,
                deviceId,
                toolName: request.toolName,
                args: request.args,
                timeoutMs: request.timeoutMs,
                emitResultToIOS: true,
            });
            if (result.error === "bridge_tool_timeout") {
                await this.cancelTimedOutClaudeRun(deviceId, request.sessionId);
                finishError = "bridge.claude.run timed out. Do not retry bridge.claude.run. Tell the user Claude Code took too long and the task did not complete.";
                return {
                    result: null,
                    error: finishError,
                };
            }
            finishError = result.error;
            return result;
        }
        catch (error) {
            finishError = error instanceof Error ? error.message : "unknown_bridge_claude_run_error";
            throw error;
        }
        finally {
            clearInterval(progressInterval);
            const commandId = this.activeClaudeCommandIdByDeviceId.get(deviceId);
            const exitCode = commandId ? this.claudeExitCodeByCommandId.get(commandId) : undefined;
            const outcome = finishError ? "error" : "ok";
            const errorPreview = finishError
                ? ` error=${summarizeValueForLog(finishError) ?? "unknown"}`
                : "";
            const exitCodePreview = typeof exitCode === "number" ? ` exitCode=${exitCode}` : "";
            logger.info(`bridge.claude.run.finish commandId=${commandId ?? "unknown"} outcome=${outcome}${exitCodePreview} durationMs=${Date.now() - startedAtMs}${errorPreview}`, {
                sessionId: request.sessionId,
                deviceId,
                callId: request.callId,
            });
            this.cleanupClaudeRun(deviceId, commandId);
        }
    }
    async executeLegacyRun(request, device) {
        const startCallId = `bridge-start-${crypto.randomUUID()}`;
        const startArgs = {
            command: optionalString(request.args.command) ?? "",
        };
        if (typeof request.args.cwd === "string") {
            startArgs.cwd = request.args.cwd;
        }
        if (typeof request.args.timeoutSec === "number") {
            startArgs.timeoutSec = request.args.timeoutSec;
        }
        if (request.args.env && typeof request.args.env === "object") {
            startArgs.env = request.args.env;
        }
        const startResult = await this.invokeBridgeTool({
            callId: startCallId,
            resultCallId: request.callId,
            sessionId: request.sessionId,
            deviceId: device.deviceId,
            toolName: "bridge.exec.start",
            args: startArgs,
            timeoutMs: request.timeoutMs,
            emitResultToIOS: false,
        });
        if (startResult.error || !startResult.result) {
            const error = startResult.error ?? "bridge_exec_start_failed";
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error,
            }));
            return { result: null, error };
        }
        const parsedStart = parseJSON(startResult.result);
        const commandId = parsedStart?.commandId;
        if (!commandId) {
            const error = "bridge_exec_start_invalid_result";
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error,
            }));
            return { result: null, error };
        }
        this.activeCommandBySession.set(request.sessionId, {
            commandId,
            deviceId: device.deviceId,
        });
        const finished = await this.waitForRunFinished(request.sessionId, request.callId, device.deviceId, commandId, request.timeoutMs);
        if (finished.error) {
            this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                callId: request.callId,
                result: null,
                error: finished.error,
            }));
            return { result: null, error: finished.error };
        }
        this.emitToIOS(makeEvent("tool.result", request.sessionId, {
            callId: request.callId,
            result: finished.result,
            error: null,
        }));
        return { result: finished.result, error: null };
    }
    invokeBridgeTool(request) {
        const outbound = makeEvent("tool.call", request.sessionId, {
            callId: request.callId,
            name: request.toolName,
            arguments: JSON.stringify(request.args),
        });
        if (!this.sendToBridge(request.deviceId, outbound)) {
            this.markOfflineAndEmitStatus(request.deviceId, request.sessionId);
            const error = "bridge_connection_unavailable";
            if (request.emitResultToIOS) {
                this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                    callId: request.resultCallId,
                    result: null,
                    error,
                }));
            }
            return Promise.resolve({ result: null, error });
        }
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this.pendingByCallId.delete(request.callId);
                // Do NOT mark the bridge offline here — a slow tool (e.g. bridge.claude.run) doesn't
                // mean the bridge connection is dead.  The WebSocket close handler will handle that.
                const timeoutError = "bridge_tool_timeout";
                if (request.emitResultToIOS) {
                    this.emitToIOS(makeEvent("tool.result", request.sessionId, {
                        callId: request.resultCallId,
                        result: null,
                        error: timeoutError,
                    }));
                }
                resolve({ result: null, error: timeoutError });
            }, request.timeoutMs);
            this.pendingByCallId.set(request.callId, {
                callId: request.callId,
                sessionId: request.sessionId,
                deviceId: request.deviceId,
                toolName: request.toolName,
                commandIdHint: optionalString(request.args.commandId),
                commandLabelHint: optionalString(request.args.command),
                resultCallId: request.resultCallId,
                emitResultToIOS: request.emitResultToIOS,
                timer,
                resolve,
            });
        });
    }
    waitForRunFinished(sessionId, toolCallId, deviceId, commandId, timeoutMs) {
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                const waiters = this.pendingRunsByCommandId.get(commandId) ?? [];
                const remaining = waiters.filter((waiter) => waiter.toolCallId !== toolCallId);
                if (remaining.length) {
                    this.pendingRunsByCommandId.set(commandId, remaining);
                }
                else {
                    this.pendingRunsByCommandId.delete(commandId);
                }
                const active = this.activeCommandBySession.get(sessionId);
                if (active?.commandId === commandId) {
                    this.activeCommandBySession.delete(sessionId);
                }
                resolve({ result: null, error: "bridge_exec_run_timeout" });
            }, timeoutMs);
            const waiters = this.pendingRunsByCommandId.get(commandId) ?? [];
            waiters.push({ sessionId, toolCallId, deviceId, timer, resolve });
            this.pendingRunsByCommandId.set(commandId, waiters);
        });
    }
    handleBridgeToolResult(event) {
        const callId = optionalString(event.payload.callId);
        if (!callId) {
            return false;
        }
        const pending = this.pendingByCallId.get(callId);
        if (!pending) {
            return false;
        }
        this.pendingByCallId.delete(callId);
        clearTimeout(pending.timer);
        const resultPayload = optionalString(event.payload.result) ?? null;
        const errorPayload = optionalString(event.payload.error) ?? null;
        if (!errorPayload && resultPayload) {
            if (pending.toolName === "bridge.exec.start") {
                const parsedStart = parseJSON(resultPayload);
                if (parsedStart?.commandId) {
                    this.activeCommandBySession.set(pending.sessionId, {
                        commandId: parsedStart.commandId,
                        deviceId: pending.deviceId,
                    });
                    this.narrationByCommandId.set(parsedStart.commandId, {
                        sessionId: pending.sessionId,
                        deviceId: pending.deviceId,
                        commandLabel: shortenForNarration(pending.commandLabelHint ?? "command"),
                        lastNarratedAtMs: Date.now(),
                        lastSpokenAtMs: Date.now(),
                    });
                    this.emitAssistantProgress(pending.sessionId, `Running ${shortenForNarration(pending.commandLabelHint ?? "command")}...`, true);
                    this.emitAssistantSpeechToolCall(pending.sessionId, `Starting ${shortenForNarration(pending.commandLabelHint ?? "command")}.`);
                }
            }
            if (pending.toolName === "bridge.exec.cancel") {
                const active = this.activeCommandBySession.get(pending.sessionId);
                if (!pending.commandIdHint || active?.commandId === pending.commandIdHint) {
                    this.activeCommandBySession.delete(pending.sessionId);
                }
                if (pending.commandIdHint) {
                    this.narrationByCommandId.delete(pending.commandIdHint);
                }
                this.emitAssistantProgress(pending.sessionId, "Stopping the running command...", true);
                this.emitAssistantSpeechToolCall(pending.sessionId, "Stopping the running command.");
            }
        }
        this.state.markDeviceOnline(pending.deviceId);
        this.emitToIOS(makeEvent("bridge.status", pending.sessionId, {
            deviceId: pending.deviceId,
            status: "online",
            lastSeen: new Date().toISOString(),
        }));
        if (pending.emitResultToIOS) {
            this.emitToIOS(makeEvent("tool.result", pending.sessionId, {
                callId: pending.resultCallId,
                result: resultPayload,
                error: errorPayload,
            }));
        }
        pending.resolve({
            result: resultPayload,
            error: errorPayload,
        });
        return true;
    }
    forwardExecOutput(event, bridgeDeviceId) {
        const payloadDeviceId = optionalString(event.payload.deviceId) ?? bridgeDeviceId;
        const commandId = optionalString(event.payload.commandId);
        const stream = optionalString(event.payload.stream);
        const chunk = typeof event.payload.chunk === "string" ? event.payload.chunk : "";
        const isFinal = typeof event.payload.isFinal === "boolean" ? event.payload.isFinal : false;
        if (!payloadDeviceId || !commandId || (stream !== "stdout" && stream !== "stderr")) {
            return false;
        }
        const device = this.state.getDevice(payloadDeviceId);
        if (!device) {
            return false;
        }
        if (stream === "stdout") {
            this.bindClaudeCommand(payloadDeviceId, commandId);
            const activeClaudeCommandId = this.activeClaudeCommandIdByDeviceId.get(payloadDeviceId);
            const activeClaude = this.activeClaudeRunByCommandId.get(commandId);
            if (activeClaude && activeClaudeCommandId === commandId) {
                this.handleClaudeOutputChunk(activeClaude.sessionId, commandId, chunk, isFinal);
            }
        }
        const targetSessionId = this.resolveExecEventSessionId(payloadDeviceId, commandId, device.sessionId);
        this.emitToIOS(makeEvent("bridge.exec.output", targetSessionId, {
            deviceId: payloadDeviceId,
            commandId,
            stream,
            chunk,
            isFinal,
        }, event.id, event.timestamp));
        const narration = this.narrationByCommandId.get(commandId);
        if (narration && narration.sessionId === targetSessionId) {
            const now = Date.now();
            const normalizedChunk = normalizeSnippet(chunk);
            const shouldNarrate = normalizedChunk.length > 0
                && (now - narration.lastNarratedAtMs >= 2_500)
                && narration.lastSnippet !== normalizedChunk;
            if (shouldNarrate) {
                narration.lastNarratedAtMs = now;
                narration.lastSnippet = normalizedChunk;
                this.emitAssistantProgress(narration.sessionId, `${narration.commandLabel}: ${stream} ${shortenForNarration(normalizedChunk, 100)}`, true);
                if (now - narration.lastSpokenAtMs >= 15_000) {
                    narration.lastSpokenAtMs = now;
                    this.emitAssistantSpeechToolCall(narration.sessionId, `${narration.commandLabel} is still running.`);
                }
            }
        }
        return true;
    }
    handleClaudeOutputChunk(sessionId, commandId, chunk, isFinal = false) {
        const buffer = (this.claudeLineBuffers.get(commandId) ?? "") + chunk;
        const lines = buffer.split("\n");
        this.claudeLineBuffers.set(commandId, lines.pop() ?? "");
        for (const line of lines) {
            this.handleClaudeOutputLine(sessionId, commandId, line);
        }
        if (isFinal) {
            this.flushClaudeOutputBuffer(sessionId, commandId);
        }
    }
    forwardExecFinished(event, bridgeDeviceId) {
        const payload = parseBridgeExecFinishedPayload(event.payload, bridgeDeviceId);
        if (!payload) {
            return false;
        }
        const device = this.state.getDevice(payload.deviceId);
        if (!device) {
            return false;
        }
        const activeClaude = this.bindClaudeCommand(payload.deviceId, payload.commandId);
        const targetSessionId = activeClaude?.sessionId
            ?? this.resolveExecEventSessionId(payload.deviceId, payload.commandId, device.sessionId);
        if (activeClaude) {
            this.flushClaudeOutputBuffer(activeClaude.sessionId, payload.commandId);
        }
        this.emitToIOS(makeEvent("bridge.exec.finished", targetSessionId, {
            deviceId: payload.deviceId,
            commandId: payload.commandId,
            exitCode: payload.exitCode,
            stdoutTail: payload.stdoutTail,
            stderrTail: payload.stderrTail,
        }, event.id, event.timestamp));
        // Check if this command belongs to an active Claude run.
        // Use the deviceId-based map for an O(1) lookup instead of iterating all values.
        const isActiveClaudeCommand = this.activeClaudeRunByCommandId.has(payload.commandId)
            || this.activeClaudeCommandIdByDeviceId.get(payload.deviceId) === payload.commandId;
        if (isActiveClaudeCommand) {
            this.claudeExitCodeByCommandId.set(payload.commandId, payload.exitCode);
        }
        else {
            this.claudeLineBuffers.delete(payload.commandId);
            this.lastClaudeProgressAt.delete(payload.commandId);
            if (this.activeClaudeCommandIdByDeviceId.get(payload.deviceId) === payload.commandId) {
                this.activeClaudeCommandIdByDeviceId.delete(payload.deviceId);
            }
        }
        const narration = this.narrationByCommandId.get(payload.commandId);
        if (narration) {
            this.emitAssistantProgress(narration.sessionId, payload.exitCode === 0
                ? `${narration.commandLabel} completed successfully.`
                : `${narration.commandLabel} finished with exit code ${payload.exitCode}.`, false);
            this.emitAssistantSpeechToolCall(narration.sessionId, payload.exitCode === 0
                ? `${narration.commandLabel} completed successfully.`
                : `${narration.commandLabel} finished with exit code ${payload.exitCode}.`);
            this.narrationByCommandId.delete(payload.commandId);
        }
        const waiters = this.pendingRunsByCommandId.get(payload.commandId) ?? [];
        if (waiters.length === 0) {
            const active = this.activeCommandBySession.get(targetSessionId);
            if (active?.commandId === payload.commandId) {
                this.activeCommandBySession.delete(targetSessionId);
            }
            return true;
        }
        this.pendingRunsByCommandId.delete(payload.commandId);
        const active = this.activeCommandBySession.get(targetSessionId);
        if (active?.commandId === payload.commandId) {
            this.activeCommandBySession.delete(targetSessionId);
        }
        const resultText = JSON.stringify({
            exitCode: payload.exitCode,
            stdout: payload.stdoutTail,
            stderr: payload.stderrTail,
        });
        for (const waiter of waiters) {
            clearTimeout(waiter.timer);
            waiter.resolve({ result: resultText, error: null });
        }
        return true;
    }
    bindClaudeCommand(deviceId, commandId) {
        const activeClaude = this.activeClaudeRunsByDeviceId.get(deviceId);
        if (!activeClaude) {
            return undefined;
        }
        const boundCommandId = this.activeClaudeCommandIdByDeviceId.get(deviceId);
        if (boundCommandId && boundCommandId !== commandId) {
            return this.activeClaudeRunByCommandId.get(boundCommandId);
        }
        if (!boundCommandId) {
            this.activeClaudeCommandIdByDeviceId.set(deviceId, commandId);
            logger.info(`bridge.claude.run.command_bound commandId=${commandId}`, {
                sessionId: activeClaude.sessionId,
                deviceId,
                callId: activeClaude.callId,
            });
        }
        this.activeClaudeRunByCommandId.set(commandId, activeClaude);
        return activeClaude;
    }
    resolveExecEventSessionId(deviceId, commandId, fallbackSessionId) {
        const activeClaude = this.activeClaudeRunByCommandId.get(commandId);
        if (activeClaude) {
            return activeClaude.sessionId;
        }
        const boundCommandId = this.activeClaudeCommandIdByDeviceId.get(deviceId);
        if (boundCommandId === commandId) {
            return this.activeClaudeRunsByDeviceId.get(deviceId)?.sessionId ?? fallbackSessionId;
        }
        return fallbackSessionId;
    }
    flushClaudeOutputBuffer(sessionId, commandId) {
        const buffer = this.claudeLineBuffers.get(commandId) ?? "";
        this.claudeLineBuffers.delete(commandId);
        if (buffer.trim()) {
            this.handleClaudeOutputLine(sessionId, commandId, buffer);
        }
    }
    handleClaudeOutputLine(sessionId, commandId, line) {
        const trimmed = line.trim();
        if (!trimmed) {
            return;
        }
        try {
            const event = JSON.parse(trimmed);
            if (event.type !== "assistant") {
                return;
            }
            const contents = Array.isArray(event.message?.content) ? event.message.content : [];
            for (const rawBlock of contents) {
                if (!rawBlock || typeof rawBlock !== "object") {
                    continue;
                }
                const block = rawBlock;
                if (block.type !== "tool_use") {
                    continue;
                }
                const label = buildClaudeProgressLabel(typeof block.name === "string" ? block.name : "", asRecord(block.input));
                if (!label) {
                    continue;
                }
                const now = Date.now();
                const last = this.lastClaudeProgressAt.get(commandId) ?? 0;
                if (now - last < 3_000) {
                    continue;
                }
                this.lastClaudeProgressAt.set(commandId, now);
                this.emitAssistantProgress(sessionId, label, true);
                this.emitAssistantSpeechToolCall(sessionId, label);
                if (this.verboseToolRoutingLogs) {
                    const runMeta = this.activeClaudeRunByCommandId.get(commandId);
                    logger.info(`bridge.claude.run.progress commandId=${commandId} label=${summarizeValueForLog(label) ?? "unknown"}`, {
                        sessionId,
                        callId: runMeta?.callId,
                    });
                }
            }
        }
        catch {
            if (this.verboseToolRoutingLogs) {
                const runMeta = this.activeClaudeRunByCommandId.get(commandId);
                logger.info(`bridge.claude.run.progress_parse_error commandId=${commandId} line=${summarizeValueForLog(trimmed) ?? "<empty>"}`, {
                    sessionId,
                    callId: runMeta?.callId,
                });
            }
        }
    }
    cleanupClaudeRun(deviceId, commandId) {
        const resolvedCommandId = commandId ?? this.activeClaudeCommandIdByDeviceId.get(deviceId);
        this.activeClaudeRunsByDeviceId.delete(deviceId);
        this.activeClaudeCommandIdByDeviceId.delete(deviceId);
        if (!resolvedCommandId) {
            return;
        }
        this.activeClaudeRunByCommandId.delete(resolvedCommandId);
        this.claudeLineBuffers.delete(resolvedCommandId);
        this.lastClaudeProgressAt.delete(resolvedCommandId);
        this.claudeExitCodeByCommandId.delete(resolvedCommandId);
    }
    async cancelTimedOutClaudeRun(deviceId, sessionId) {
        const commandId = this.activeClaudeCommandIdByDeviceId.get(deviceId);
        if (!commandId) {
            return;
        }
        const callId = `bridge-claude-timeout-cancel-${crypto.randomUUID()}`;
        await this.invokeBridgeTool({
            callId,
            resultCallId: callId,
            sessionId,
            deviceId,
            toolName: "bridge.exec.cancel",
            args: { commandId },
            timeoutMs: 5_000,
            emitResultToIOS: false,
        });
    }
    markOfflineAndEmitStatus(deviceId, sessionId) {
        const updated = this.state.markDeviceOffline(deviceId);
        if (!updated) {
            return;
        }
        this.emitToIOS(makeEvent("bridge.status", sessionId, {
            deviceId: updated.deviceId,
            status: "offline",
            lastSeen: updated.lastSeen,
        }));
    }
    emitAssistantProgress(sessionId, text, isPartial) {
        this.emitToIOS(makeEvent(isPartial ? "assistant.speech.partial" : "assistant.speech.final", sessionId, { text }));
    }
    emitAssistantSpeechToolCall(sessionId, text) {
        this.emitToIOS(makeEvent("tool.call", sessionId, {
            callId: `bridge-tts-${crypto.randomUUID()}`,
            name: "tts.speak",
            arguments: JSON.stringify({ text }),
        }));
    }
}
function asRecord(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        return {};
    }
    return value;
}
function parseJSON(value) {
    try {
        return JSON.parse(value);
    }
    catch {
        return undefined;
    }
}
function normalizeSnippet(value) {
    return value.replace(/\s+/g, " ").trim();
}
function shortenForNarration(value, max = 60) {
    const trimmed = value.trim();
    if (trimmed.length <= max) {
        return trimmed;
    }
    return `${trimmed.slice(0, max - 1)}…`;
}
function buildClaudeProgressLabel(toolName, input) {
    switch (toolName) {
        case "Bash": {
            const cmd = String(input.command ?? "").slice(0, 60);
            return cmd ? `Running terminal command: ${cmd}` : "Running a terminal command";
        }
        case "Read": {
            const path = input.file_path ?? input.path;
            return path ? `Reading ${path}` : null;
        }
        case "Write": {
            const path = input.file_path ?? input.path;
            return path ? `Writing ${path}` : null;
        }
        case "Edit": {
            const path = input.file_path ?? input.path;
            return path ? `Editing ${path}` : null;
        }
        case "Glob":
            return "Searching for files";
        case "Grep":
            return input.pattern ? `Searching for: ${input.pattern}` : "Searching code";
        case "WebFetch":
            return "Fetching a web page";
        case "WebSearch":
            return input.query ? `Searching the web: ${input.query}` : "Searching the web";
        case "LS":
            return "Listing files";
        case "MultiEdit":
            return "Applying multiple edits";
        default:
            return toolName ? `Using ${toolName}` : null;
    }
}
function parseBridgeExecFinishedPayload(payload, bridgeDeviceId) {
    const deviceId = optionalString(payload.deviceId) ?? bridgeDeviceId;
    const commandId = optionalString(payload.commandId);
    const stdoutTail = typeof payload.stdoutTail === "string" ? payload.stdoutTail : "";
    const stderrTail = typeof payload.stderrTail === "string" ? payload.stderrTail : "";
    const exitCode = typeof payload.exitCode === "number" ? Math.trunc(payload.exitCode) : undefined;
    if (!deviceId || !commandId || typeof exitCode !== "number") {
        return undefined;
    }
    return {
        deviceId,
        commandId,
        exitCode,
        stdoutTail,
        stderrTail,
    };
}

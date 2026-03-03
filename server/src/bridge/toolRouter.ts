import crypto from "node:crypto";

import { makeEvent } from "../core/events.js";
import { EventEnvelope } from "../core/types.js";
import { BridgeDeviceRecord, BridgeStateStore } from "./state.js";

interface PendingBridgeCall {
  callId: string;
  sessionId: string;
  deviceId: string;
  toolName: string;
  commandIdHint?: string;
  commandLabelHint?: string;
  resultCallId: string;
  emitResultToIOS: boolean;
  resolve: (result: { result: string | null; error: string | null }) => void;
  timer: NodeJS.Timeout;
}

interface PendingRunWaiter {
  sessionId: string;
  toolCallId: string;
  deviceId: string;
  timer: NodeJS.Timeout;
  resolve: (result: { result: string | null; error: string | null }) => void;
}

interface CommandNarrationState {
  sessionId: string;
  deviceId: string;
  commandLabel: string;
  lastNarratedAtMs: number;
  lastSpokenAtMs: number;
  lastSnippet?: string;
}

interface BridgeExecStartResult {
  commandId: string;
  startedAt: string;
}

interface BridgeExecFinishedPayload {
  deviceId: string;
  commandId: string;
  exitCode: number;
  stdoutTail: string;
  stderrTail: string;
}

export interface BridgeToolRouteRequest {
  callId: string;
  sessionId: string;
  toolName: string;
  args: Record<string, unknown>;
  timeoutMs: number;
}

export interface BridgeToolRouterDependencies {
  state: BridgeStateStore;
  sendToBridge: (deviceId: string, event: EventEnvelope) => boolean;
  emitToIOS: (event: EventEnvelope) => void;
}

export class BridgeToolRouter {
  private readonly state: BridgeStateStore;
  private readonly sendToBridge: (deviceId: string, event: EventEnvelope) => boolean;
  private readonly emitToIOS: (event: EventEnvelope) => void;
  private readonly pendingByCallId = new Map<string, PendingBridgeCall>();
  private readonly pendingRunsByCommandId = new Map<string, PendingRunWaiter[]>();
  private readonly activeCommandBySession = new Map<string, { commandId: string; deviceId: string }>();
  private readonly narrationByCommandId = new Map<string, CommandNarrationState>();

  constructor(deps: BridgeToolRouterDependencies) {
    this.state = deps.state;
    this.sendToBridge = deps.sendToBridge;
    this.emitToIOS = deps.emitToIOS;
  }

  async execute(request: BridgeToolRouteRequest): Promise<{ result: string | null; error: string | null }> {
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

    // Keep iOS timeline visibility for every bridge tool call.
    this.emitToIOS(makeEvent("tool.call", request.sessionId, {
      callId: request.callId,
      name: request.toolName,
      arguments: JSON.stringify(request.args),
    }));

    if (request.toolName === "bridge.exec.run") {
      return await this.executeLegacyRun(request, resolved.device);
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

  handleBridgeEvent(event: EventEnvelope, bridgeDeviceId?: string): boolean {
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

  async cancelActiveCommand(sessionId: string): Promise<boolean> {
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

  failPendingForDevice(deviceId: string): void {
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
      } else {
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
  }

  private async executeLegacyRun(
    request: BridgeToolRouteRequest,
    device: BridgeDeviceRecord,
  ): Promise<{ result: string | null; error: string | null }> {
    const startCallId = `bridge-start-${crypto.randomUUID()}`;
    const startArgs: Record<string, unknown> = {
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

    const parsedStart = parseJSON<BridgeExecStartResult>(startResult.result);
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

    const finished = await this.waitForRunFinished(
      request.sessionId,
      request.callId,
      device.deviceId,
      commandId,
      request.timeoutMs,
    );

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

  private invokeBridgeTool(request: {
    callId: string;
    resultCallId: string;
    sessionId: string;
    deviceId: string;
    toolName: string;
    args: Record<string, unknown>;
    timeoutMs: number;
    emitResultToIOS: boolean;
  }): Promise<{ result: string | null; error: string | null }> {
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
        this.markOfflineAndEmitStatus(request.deviceId, request.sessionId);

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

  private waitForRunFinished(
    sessionId: string,
    toolCallId: string,
    deviceId: string,
    commandId: string,
    timeoutMs: number,
  ): Promise<{ result: string | null; error: string | null }> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const waiters = this.pendingRunsByCommandId.get(commandId) ?? [];
        const remaining = waiters.filter((waiter) => waiter.toolCallId !== toolCallId);
        if (remaining.length) {
          this.pendingRunsByCommandId.set(commandId, remaining);
        } else {
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

  private handleBridgeToolResult(event: EventEnvelope): boolean {
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
        const parsedStart = parseJSON<BridgeExecStartResult>(resultPayload);
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
          this.emitAssistantProgress(
            pending.sessionId,
            `Running ${shortenForNarration(pending.commandLabelHint ?? "command")}...`,
            true,
          );
          this.emitAssistantSpeechToolCall(
            pending.sessionId,
            `Starting ${shortenForNarration(pending.commandLabelHint ?? "command")}.`,
          );
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

  private forwardExecOutput(event: EventEnvelope, bridgeDeviceId?: string): boolean {
    const payloadDeviceId = optionalString(event.payload.deviceId) ?? bridgeDeviceId;
    const commandId = optionalString(event.payload.commandId);
    const stream = optionalString(event.payload.stream);
    const chunk = optionalString(event.payload.chunk) ?? "";
    const isFinal = typeof event.payload.isFinal === "boolean" ? event.payload.isFinal : false;

    if (!payloadDeviceId || !commandId || (stream !== "stdout" && stream !== "stderr")) {
      return false;
    }

    const device = this.state.getDevice(payloadDeviceId);
    if (!device) {
      return false;
    }

    this.emitToIOS(makeEvent("bridge.exec.output", device.sessionId, {
      deviceId: payloadDeviceId,
      commandId,
      stream,
      chunk,
      isFinal,
    }, event.id, event.timestamp));

    const narration = this.narrationByCommandId.get(commandId);
    if (narration && narration.sessionId === device.sessionId) {
      const now = Date.now();
      const normalizedChunk = normalizeSnippet(chunk);
      const shouldNarrate = normalizedChunk.length > 0
        && (now - narration.lastNarratedAtMs >= 2_500)
        && narration.lastSnippet !== normalizedChunk;

      if (shouldNarrate) {
        narration.lastNarratedAtMs = now;
        narration.lastSnippet = normalizedChunk;
        this.emitAssistantProgress(
          narration.sessionId,
          `${narration.commandLabel}: ${stream} ${shortenForNarration(normalizedChunk, 100)}`,
          true,
        );

        if (now - narration.lastSpokenAtMs >= 15_000) {
          narration.lastSpokenAtMs = now;
          this.emitAssistantSpeechToolCall(
            narration.sessionId,
            `${narration.commandLabel} is still running.`,
          );
        }
      }
    }

    return true;
  }

  private forwardExecFinished(event: EventEnvelope, bridgeDeviceId?: string): boolean {
    const payload = parseBridgeExecFinishedPayload(event.payload, bridgeDeviceId);
    if (!payload) {
      return false;
    }

    const device = this.state.getDevice(payload.deviceId);
    if (!device) {
      return false;
    }

    this.emitToIOS(makeEvent("bridge.exec.finished", device.sessionId, {
      deviceId: payload.deviceId,
      commandId: payload.commandId,
      exitCode: payload.exitCode,
      stdoutTail: payload.stdoutTail,
      stderrTail: payload.stderrTail,
    }, event.id, event.timestamp));

    const narration = this.narrationByCommandId.get(payload.commandId);
    if (narration) {
      this.emitAssistantProgress(
        narration.sessionId,
        payload.exitCode === 0
          ? `${narration.commandLabel} completed successfully.`
          : `${narration.commandLabel} finished with exit code ${payload.exitCode}.`,
        false,
      );
      this.emitAssistantSpeechToolCall(
        narration.sessionId,
        payload.exitCode === 0
          ? `${narration.commandLabel} completed successfully.`
          : `${narration.commandLabel} finished with exit code ${payload.exitCode}.`,
      );
      this.narrationByCommandId.delete(payload.commandId);
    }

    const waiters = this.pendingRunsByCommandId.get(payload.commandId) ?? [];
    if (waiters.length === 0) {
      const active = this.activeCommandBySession.get(device.sessionId);
      if (active?.commandId === payload.commandId) {
        this.activeCommandBySession.delete(device.sessionId);
      }
      return true;
    }

    this.pendingRunsByCommandId.delete(payload.commandId);
    const active = this.activeCommandBySession.get(device.sessionId);
    if (active?.commandId === payload.commandId) {
      this.activeCommandBySession.delete(device.sessionId);
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

  private markOfflineAndEmitStatus(deviceId: string, sessionId: string): void {
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

  private emitAssistantProgress(sessionId: string, text: string, isPartial: boolean): void {
    this.emitToIOS(makeEvent(
      isPartial ? "assistant.speech.partial" : "assistant.speech.final",
      sessionId,
      { text },
    ));
  }

  private emitAssistantSpeechToolCall(sessionId: string, text: string): void {
    this.emitToIOS(makeEvent("tool.call", sessionId, {
      callId: `bridge-tts-${crypto.randomUUID()}`,
      name: "tts.speak",
      arguments: JSON.stringify({ text }),
    }));
  }
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function parseJSON<T>(value: string): T | undefined {
  try {
    return JSON.parse(value) as T;
  } catch {
    return undefined;
  }
}

function normalizeSnippet(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function shortenForNarration(value: string, max = 60): string {
  const trimmed = value.trim();
  if (trimmed.length <= max) {
    return trimmed;
  }
  return `${trimmed.slice(0, max - 1)}…`;
}

function parseBridgeExecFinishedPayload(
  payload: Record<string, unknown>,
  bridgeDeviceId?: string,
): BridgeExecFinishedPayload | undefined {
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

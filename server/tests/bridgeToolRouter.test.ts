import test from "node:test";
import assert from "node:assert/strict";

import { BridgeStateStore } from "../src/bridge/state.js";
import { BridgeToolRouter } from "../src/bridge/toolRouter.js";
import { makeEvent } from "../src/core/events.js";
import { logger } from "../src/core/logger.js";

type CapturedInfoLog = {
  message: string;
  context?: Record<string, unknown>;
};

function captureInfoLogs(): { entries: CapturedInfoLog[]; restore: () => void } {
  const entries: CapturedInfoLog[] = [];
  const original = logger.info;
  logger.info = (message: string, context?: Record<string, unknown>) => {
    entries.push({ message, context });
  };
  return {
    entries,
    restore: () => {
      logger.info = original;
    },
  };
}

function setupRouter() {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-bridge", "PAIR77", "Mac");
  const registration = state.registerBridge({
    pairingCode: "PAIR77",
    deviceId: "device-bridge",
    deviceName: "Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });
  assert.ok(registration.device);
  return state;
}

test("bridge tool routing forwards tool.call and resolves tool.result", async () => {
  const state = setupRouter();
  let forwardedCallId = "";
  const emitted: string[] = [];

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      forwardedCallId = String(event.payload.callId);
      setImmediate(() => {
        router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
          callId: String(event.payload.callId),
          result: JSON.stringify({ content: "ok" }),
          error: null,
        }), "device-bridge");
      });
      return true;
    },
    emitToIOS: (event) => {
      emitted.push(event.type);
    },
  });

  const output = await router.execute({
    callId: "call-1",
    sessionId: "session-bridge",
    toolName: "bridge.fs.readFile",
    args: { path: "README.md" },
    timeoutMs: 200,
  });

  assert.equal(forwardedCallId, "call-1");
  assert.equal(output.error, null);
  assert.ok(output.result?.includes("content"));
  assert.deepEqual(emitted, ["tool.call", "bridge.status", "tool.result"]);
});

test("bridge.claude.run routes through bridge tool router", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude", "CLAUD1", "Claude Mac");
  const registration = state.registerBridge({
    pairingCode: "CLAUD1",
    deviceId: "device-claude",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });
  assert.ok(registration.device);

  let forwardedToolName = "";
  const emitted: string[] = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      forwardedToolName = String(event.payload.name);
      setImmediate(() => {
        router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
          callId: String(event.payload.callId),
          result: JSON.stringify({ result: "Fixed the failing test", sessionId: null }),
          error: null,
        }));
      });
      return true;
    },
    emitToIOS: (event) => {
      emitted.push(event.type);
    },
  });

  const output = await router.execute({
    callId: "call-claude-1",
    sessionId: "session-claude",
    toolName: "bridge.claude.run",
    args: { prompt: "fix the failing test" },
    timeoutMs: 200,
  });

  assert.equal(forwardedToolName, "bridge.claude.run");
  assert.equal(output.error, null);
  assert.ok(output.result?.includes("Fixed the failing test"));
});

test("bridge.claude.run rejects concurrent runs on the same device", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-a", "CLAUD2", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLAUD2",
    deviceId: "device-claude-shared",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  state.createPairingRequest("session-claude-b", "CLAUD3", "Claude Mac B");
  state.registerBridge({
    pairingCode: "CLAUD3",
    deviceId: "device-claude-shared",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  let resolveFirst: (() => void) | undefined;
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      if (String(event.payload.name) === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-shared", {
            deviceId: "device-claude-shared",
            commandId: "cmd-claude-shared",
            stream: "stdout",
            chunk: "",
            isFinal: false,
          }), "device-claude-shared");
        });

        void new Promise<void>((resolve) => {
          resolveFirst = resolve;
        }).then(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId: String(event.payload.callId),
            result: JSON.stringify({ result: "done" }),
            error: null,
          }), "device-claude-shared");
        });
      }
      return true;
    },
    emitToIOS: () => undefined,
  });

  const firstRun = router.execute({
    callId: "call-claude-a",
    sessionId: "session-claude-a",
    toolName: "bridge.claude.run",
    args: { prompt: "first task" },
    timeoutMs: 500,
  });

  await new Promise((resolve) => setImmediate(resolve));

  const secondRun = await router.execute({
    callId: "call-claude-b",
    sessionId: "session-claude-b",
    toolName: "bridge.claude.run",
    args: { deviceId: "device-claude-shared", prompt: "second task" },
    timeoutMs: 500,
  });

  assert.match(secondRun.error ?? "", /already active on this device/);

  resolveFirst?.();
  const firstResult = await firstRun;
  assert.equal(firstResult.error, null);
});


test("bridge tool routing returns timeout without forcing offline status", async () => {
  const state = setupRouter();

  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: () => true,
    emitToIOS: (event) => {
      emitted.push({ type: event.type, payload: event.payload });
    },
  });

  const output = await router.execute({
    callId: "call-timeout",
    sessionId: "session-bridge",
    toolName: "bridge.fs.readFile",
    args: { path: "README.md" },
    timeoutMs: 30,
  });

  assert.equal(output.result, null);
  assert.equal(output.error, "bridge_tool_timeout");
  const offlineStatusEvent = emitted.find((event) => (
    event.type === "bridge.status" && event.payload.status === "offline"
  ));
  assert.equal(offlineStatusEvent, undefined);
});

test("bridge.exec.run compatibility path forwards stream and resolves after finished", async () => {
  const state = setupRouter();
  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const toolName = String(event.payload.name);
      const callId = String(event.payload.callId);

      if (toolName === "bridge.exec.start") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ commandId: "cmd-1", startedAt: new Date().toISOString() }),
            error: null,
          }), "device-bridge");
          setImmediate(() => {
            router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-bridge", {
              deviceId: "device-bridge",
              commandId: "cmd-1",
              stream: "stdout",
              chunk: "line 1\n",
              isFinal: false,
            }), "device-bridge");

            router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-bridge", {
              deviceId: "device-bridge",
              commandId: "cmd-1",
              exitCode: 0,
              stdoutTail: "line 1\n",
              stderrTail: "",
            }), "device-bridge");
          });
        });
      }

      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ type: event.type, payload: event.payload });
    },
  });

  const output = await router.execute({
    callId: "call-run",
    sessionId: "session-bridge",
    toolName: "bridge.exec.run",
    args: { command: "echo hi" },
    timeoutMs: 200,
  });

  assert.equal(output.error, null);
  assert.ok(output.result?.includes("exitCode"));

  const outputEvent = emitted.find((event) => event.type === "bridge.exec.output");
  assert.ok(outputEvent);
  const finishedEvent = emitted.find((event) => event.type === "bridge.exec.finished");
  assert.ok(finishedEvent);
  const toolResult = emitted.find((event) => event.type === "tool.result");
  assert.ok(toolResult);
});

test("cancelActiveCommand issues bridge.exec.cancel", async () => {
  const state = setupRouter();
  let sawCancel = false;

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const toolName = String(event.payload.name);
      const callId = String(event.payload.callId);
      if (toolName === "bridge.exec.start") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ commandId: "cmd-22", startedAt: new Date().toISOString() }),
            error: null,
          }), "device-bridge");
        });
      }

      if (toolName === "bridge.exec.cancel") {
        sawCancel = true;
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ cancelled: true }),
            error: null,
          }), "device-bridge");
        });
      }

      return true;
    },
    emitToIOS: () => {},
  });

  await router.execute({
    callId: "call-start",
    sessionId: "session-bridge",
    toolName: "bridge.exec.start",
    args: { command: "sleep 1" },
    timeoutMs: 200,
  });

  const cancelled = await router.cancelActiveCommand("session-bridge");
  assert.equal(cancelled, true);
  assert.equal(sawCancel, true);
});

test("bridge.exec.output is routed to paired session", () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-a", "AAAA11", "Mac A");
  state.registerBridge({
    pairingCode: "AAAA11",
    deviceId: "device-a",
    deviceName: "Mac A",
    workspaceRoot: "/workspace-a",
    capabilities: { execRun: true, readFile: true },
  });

  state.createPairingRequest("session-b", "BBBB22", "Mac B");
  state.registerBridge({
    pairingCode: "BBBB22",
    deviceId: "device-b",
    deviceName: "Mac B",
    workspaceRoot: "/workspace-b",
    capabilities: { execRun: true, readFile: true },
  });

  const emitted: Array<{ sessionId: string; type: string }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: () => true,
    emitToIOS: (event) => {
      emitted.push({ sessionId: event.sessionId, type: event.type });
    },
  });

  const handled = router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-b", {
    deviceId: "device-b",
    commandId: "cmd-77",
    stream: "stdout",
    chunk: "hello",
    isFinal: false,
  }), "device-b");

  assert.equal(handled, true);
  const routed = emitted.find((event) => event.type === "bridge.exec.output");
  assert.ok(routed);
  assert.equal(routed?.sessionId, "session-b");
});

test("router can execute for a new iOS session when only one bridge is globally online", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-old", "ONE111", "Only Mac");
  state.registerBridge({
    pairingCode: "ONE111",
    deviceId: "device-only",
    deviceName: "Only Mac",
    workspaceRoot: "/workspace-only",
    capabilities: { execRun: true, readFile: true },
  });

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      setImmediate(() => {
        router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
          callId: String(event.payload.callId),
          result: JSON.stringify({ content: "from-global-fallback" }),
          error: null,
        }), "device-only");
      });
      return true;
    },
    emitToIOS: () => {},
  });

  const output = await router.execute({
    callId: "call-fallback",
    sessionId: "session-new",
    toolName: "bridge.fs.readFile",
    args: { path: "README.md" },
    timeoutMs: 200,
  });

  assert.equal(output.error, null);
  assert.ok(output.result?.includes("from-global-fallback"));
});

test("bridge.exec streaming events follow reassociated session after reconnect fallback", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-old", "ONE222", "Only Mac");
  state.registerBridge({
    pairingCode: "ONE222",
    deviceId: "device-only",
    deviceName: "Only Mac",
    workspaceRoot: "/workspace-only",
    capabilities: { execRun: true, readFile: true },
  });

  const emitted: Array<{ sessionId: string; type: string }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const toolName = String(event.payload.name);
      const callId = String(event.payload.callId);

      if (toolName === "bridge.exec.start") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ commandId: "cmd-reconnect", startedAt: new Date().toISOString() }),
            error: null,
          }), "device-only");
          setImmediate(() => {
            router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-only", {
              deviceId: "device-only",
              commandId: "cmd-reconnect",
              stream: "stdout",
              chunk: "still running\n",
              isFinal: false,
            }), "device-only");
            router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-only", {
              deviceId: "device-only",
              commandId: "cmd-reconnect",
              exitCode: 0,
              stdoutTail: "done\n",
              stderrTail: "",
            }), "device-only");
          });
        });
      }

      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ sessionId: event.sessionId, type: event.type });
    },
  });

  const output = await router.execute({
    callId: "call-reconnect-run",
    sessionId: "session-new",
    toolName: "bridge.exec.run",
    args: { command: "npm test" },
    timeoutMs: 400,
  });

  assert.equal(output.error, null);
  const outputEvent = emitted.find((event) => event.type === "bridge.exec.output");
  const finishedEvent = emitted.find((event) => event.type === "bridge.exec.finished");
  assert.equal(outputEvent?.sessionId, "session-new");
  assert.equal(finishedEvent?.sessionId, "session-new");
});

test("bridge.claude.run emits lifecycle logs", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-logs", "CLG111", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLG111",
    deviceId: "device-claude-logs",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const callId = String(event.payload.callId);
      if (String(event.payload.name) === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-logs", {
            deviceId: "device-claude-logs",
            commandId: "cmd-claude-logs",
            stream: "stdout",
            chunk: "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"test.txt\"}}]}}\n",
            isFinal: false,
          }), "device-claude-logs");
          router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-claude-logs", {
            deviceId: "device-claude-logs",
            commandId: "cmd-claude-logs",
            exitCode: 0,
            stdoutTail: "",
            stderrTail: "",
          }), "device-claude-logs");
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ result: "done" }),
            error: null,
          }), "device-claude-logs");
        });
      }
      return true;
    },
    emitToIOS: () => undefined,
  });

  const logs = captureInfoLogs();
  try {
    const output = await router.execute({
      callId: "call-claude-logs",
      sessionId: "session-claude-logs",
      toolName: "bridge.claude.run",
      args: { prompt: "do stuff" },
      timeoutMs: 500,
    });
    assert.equal(output.error, null);
  } finally {
    logs.restore();
  }

  assert.ok(logs.entries.some((entry) => entry.message.includes("bridge.claude.run.start")));
  assert.ok(logs.entries.some((entry) => entry.message.includes("bridge.claude.run.command_bound commandId=cmd-claude-logs")));
  assert.ok(logs.entries.some((entry) => entry.message.includes("bridge.claude.run.finish commandId=cmd-claude-logs")));
});

test("bridge.claude.run verbose mode logs parsed tool_use progress", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-progress", "CLG222", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLG222",
    deviceId: "device-claude-progress",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  const assistantToolUseLine = JSON.stringify({
    type: "assistant",
    message: {
      content: [{
        type: "tool_use",
        name: "Bash",
        input: { command: "npm test" },
      }],
    },
  }) + "\n";

  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];
  const router = new BridgeToolRouter({
    state,
    verboseToolRoutingLogs: true,
    sendToBridge: (_deviceId, event) => {
      const callId = String(event.payload.callId);
      if (String(event.payload.name) === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-progress", {
            deviceId: "device-claude-progress",
            commandId: "cmd-claude-progress",
            stream: "stdout",
            chunk: assistantToolUseLine,
            isFinal: false,
          }), "device-claude-progress");
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId,
            result: JSON.stringify({ result: "done" }),
            error: null,
          }), "device-claude-progress");
        });
      }
      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ type: event.type, payload: event.payload });
    },
  });

  const logs = captureInfoLogs();
  try {
    const output = await router.execute({
      callId: "call-claude-progress",
      sessionId: "session-claude-progress",
      toolName: "bridge.claude.run",
      args: { prompt: "run tests" },
      timeoutMs: 500,
    });
    assert.equal(output.error, null);
  } finally {
    logs.restore();
  }

  const narratedProgress = emitted.some((event) => (
    event.type === "tool.call"
    && event.payload.name === "tts.speak"
    && typeof event.payload.arguments === "string"
    && event.payload.arguments.includes("Running terminal command: npm test")
  ));
  assert.equal(
    narratedProgress,
    true,
    `expected parsed tool_use narration, emitted=${JSON.stringify(emitted)} logs=${JSON.stringify(logs.entries.map((entry) => entry.message))}`,
  );
  assert.ok(
    logs.entries.some((entry) => entry.message.includes("bridge.claude.run.progress")),
    `expected progress log, got: ${logs.entries.map((entry) => entry.message).join(" | ")}`,
  );
});

test("bridge.claude.run routes exec output to the initiating session after reassociation", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-origin", "CLG333", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLG333",
    deviceId: "device-claude-route",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  const emitted: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      if (String(event.payload.name) === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-route", {
            deviceId: "device-claude-route",
            commandId: "cmd-claude-route",
            stream: "stdout",
            chunk: "",
            isFinal: false,
          }), "device-claude-route");

          state.createPairingRequest("session-rebound", "CLG444", "Claude Mac");
          state.registerBridge({
            pairingCode: "CLG444",
            deviceId: "device-claude-route",
            deviceName: "Claude Mac",
            workspaceRoot: "/workspace",
            capabilities: { execRun: true, readFile: true, claudeRun: true },
          });

          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-route", {
            deviceId: "device-claude-route",
            commandId: "cmd-claude-route",
            stream: "stdout",
            chunk: "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"test.txt\"}}]}}\n",
            isFinal: false,
          }), "device-claude-route");
          router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-claude-route", {
            deviceId: "device-claude-route",
            commandId: "cmd-claude-route",
            exitCode: 0,
            stdoutTail: "",
            stderrTail: "",
          }), "device-claude-route");
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId: String(event.payload.callId),
            result: JSON.stringify({ result: "done" }),
            error: null,
          }), "device-claude-route");
        });
      }
      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ sessionId: event.sessionId, type: event.type, payload: event.payload });
    },
  });

  const result = await router.execute({
    callId: "call-claude-route",
    sessionId: "session-claude-origin",
    toolName: "bridge.claude.run",
    args: { prompt: "write a file" },
    timeoutMs: 500,
  });

  assert.equal(result.error, null);
  const outputEvent = emitted.find((event) => (
    event.type === "bridge.exec.output"
    && event.payload.commandId === "cmd-claude-route"
    && event.payload.chunk !== ""
  ));
  const finishedEvent = emitted.find((event) => (
    event.type === "bridge.exec.finished"
    && event.payload.commandId === "cmd-claude-route"
  ));
  assert.equal(outputEvent?.sessionId, "session-claude-origin");
  assert.equal(finishedEvent?.sessionId, "session-claude-origin");
});

test("bridge.claude.run flushes a final partial stream-json line on finish", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-flush", "CLG555", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLG555",
    deviceId: "device-claude-flush",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      if (String(event.payload.name) === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-flush", {
            deviceId: "device-claude-flush",
            commandId: "cmd-claude-flush",
            stream: "stdout",
            chunk: "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"npm test\"}}]}}",
            isFinal: false,
          }), "device-claude-flush");
          router.handleBridgeEvent(makeEvent("bridge.exec.finished", "device-claude-flush", {
            deviceId: "device-claude-flush",
            commandId: "cmd-claude-flush",
            exitCode: 0,
            stdoutTail: "",
            stderrTail: "",
          }), "device-claude-flush");
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId: String(event.payload.callId),
            result: JSON.stringify({ result: "done" }),
            error: null,
          }), "device-claude-flush");
        });
      }
      return true;
    },
    emitToIOS: (event) => {
      emitted.push({ type: event.type, payload: event.payload });
    },
  });

  const result = await router.execute({
    callId: "call-claude-flush",
    sessionId: "session-claude-flush",
    toolName: "bridge.claude.run",
    args: { prompt: "run tests" },
    timeoutMs: 500,
  });

  assert.equal(result.error, null);
  assert.ok(emitted.some((event) => (
    event.type === "tool.call"
    && event.payload.name === "tts.speak"
    && typeof event.payload.arguments === "string"
    && event.payload.arguments.includes("Running terminal command: npm test")
  )));
});

test("bridge.claude.run timeout triggers a best-effort cancel when commandId is known", async () => {
  const state = new BridgeStateStore();
  state.createPairingRequest("session-claude-timeout", "CLG666", "Claude Mac");
  state.registerBridge({
    pairingCode: "CLG666",
    deviceId: "device-claude-timeout",
    deviceName: "Claude Mac",
    workspaceRoot: "/workspace",
    capabilities: { execRun: true, readFile: true, claudeRun: true },
  });

  let sawCancel = false;
  const router = new BridgeToolRouter({
    state,
    sendToBridge: (_deviceId, event) => {
      const name = String(event.payload.name);
      if (name === "bridge.claude.run") {
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("bridge.exec.output", "device-claude-timeout", {
            deviceId: "device-claude-timeout",
            commandId: "cmd-claude-timeout",
            stream: "stdout",
            chunk: "",
            isFinal: false,
          }), "device-claude-timeout");
        });
      }

      if (name === "bridge.exec.cancel") {
        sawCancel = true;
        setImmediate(() => {
          router.handleBridgeEvent(makeEvent("tool.result", "bridge-session", {
            callId: String(event.payload.callId),
            result: JSON.stringify({ cancelled: true }),
            error: null,
          }), "device-claude-timeout");
        });
      }
      return true;
    },
    emitToIOS: () => undefined,
  });

  const result = await router.execute({
    callId: "call-claude-timeout",
    sessionId: "session-claude-timeout",
    toolName: "bridge.claude.run",
    args: { prompt: "slow task" },
    timeoutMs: 30,
  });

  assert.match(result.error ?? "", /timed out/);
  assert.equal(sawCancel, true);
});

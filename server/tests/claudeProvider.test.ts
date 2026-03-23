import test from "node:test";
import assert from "node:assert/strict";
import { ClaudeProvider } from "../src/providers/claudeProvider.js";
import { ConversationTurn, ToolDefinition } from "../src/core/types.js";

// Helper to access private methods for unit testing.
// We test through the public interface where possible, but buildMessages
// and tool name logic are internal and need direct testing.
function createProvider() {
  return new ClaudeProvider({
    apiKey: "test-key",
    model: "claude-haiku-4-5",
    maxTokens: 4096,
  });
}

test("buildMessages skips system turns", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "system", content: "You are a helpful assistant" },
    { role: "user", content: "Hello" },
    { role: "assistant", content: "Hi there" },
  ];
  const messages = provider.buildMessages(turns);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].role, "user");
  assert.equal(messages[1].role, "assistant");
});

test("buildMessages batches consecutive tool results into one user message", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "user", content: "Do stuff" },
    {
      role: "assistant",
      content: [
        { id: "tc1", name: "gmail_inbox", input: {} },
        { id: "tc2", name: "calendar_list", input: {} },
      ],
    },
    { role: "tool", content: '{"emails":[]}', tool_use_id: "tc1", tool_name: "gmail_inbox" },
    { role: "tool", content: '{"events":[]}', tool_use_id: "tc2", tool_name: "calendar_list" },
  ];
  const messages = provider.buildMessages(turns);
  // user, assistant (tool_use), user (batched tool_results)
  assert.equal(messages.length, 3);
  const toolResultMsg = messages[2];
  assert.equal(toolResultMsg.role, "user");
  assert.ok(Array.isArray(toolResultMsg.content));
  assert.equal(toolResultMsg.content.length, 2);
  assert.equal(toolResultMsg.content[0].type, "tool_result");
  assert.equal(toolResultMsg.content[1].type, "tool_result");
});

test("buildMessages drops orphaned tool calls", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "user", content: "Hello" },
    {
      role: "assistant",
      content: [
        { id: "tc1", name: "tool_a", input: {} },
        { id: "tc2", name: "tool_b", input: {} },
      ],
    },
    // Only tc1 has a result — tc2 is orphaned
    { role: "tool", content: "result1", tool_use_id: "tc1", tool_name: "tool_a" },
    { role: "user", content: "Continue" },
  ];
  const messages = provider.buildMessages(turns);
  // user, assistant (only tc1 — tc2 filtered), user (tool_result for tc1), user
  const assistantMsg = messages[1];
  assert.ok(Array.isArray(assistantMsg.content));
  assert.equal(assistantMsg.content.length, 1);
  assert.equal(assistantMsg.content[0].id, "tc1");
});

test("buildMessages ensures first message is user role", () => {
  const provider = createProvider() as any;
  const turns: ConversationTurn[] = [
    { role: "assistant", content: "I start" },
    { role: "user", content: "Hello" },
  ];
  const messages = provider.buildMessages(turns);
  assert.equal(messages[0].role, "user");
});

test("tool names: dots replaced with underscores", () => {
  const provider = createProvider() as any;
  const tools: ToolDefinition[] = [
    { name: "gmail.inbox", description: "Get inbox", input_schema: { type: "object", properties: {} } },
    { name: "bridge.exec.run", description: "Run cmd", input_schema: { type: "object", properties: {} } },
  ];
  const { safeTools, toolNameToOriginal } = provider.prepareTools(tools);
  assert.equal(safeTools[0].name, "gmail_inbox");
  assert.equal(safeTools[1].name, "bridge_exec_run");
  assert.equal(toolNameToOriginal.get("gmail_inbox"), "gmail.inbox");
  assert.equal(toolNameToOriginal.get("bridge_exec_run"), "bridge.exec.run");
});

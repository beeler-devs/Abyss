/**
 * Tests for the conductor orchestration logic.
 *
 * We mock:
 * - Bedrock (converseStream) to return controlled chunks
 * - DynamoDB operations
 * - WebSocket sendToConnection
 */

import { handleTranscriptFinal, handleToolResult } from '../src/services/conductor';
import * as bedrockModule from '../src/services/bedrock';
import * as dynamoModule from '../src/services/dynamodb';
import * as wsModule from '../src/services/websocket';
import { SessionRecord } from '../src/models/session';

// ─── Mocks ──────────────────────────────────────────────────────────────────

jest.mock('../src/services/bedrock');
jest.mock('../src/services/dynamodb');
jest.mock('../src/services/websocket');

const mockDynamo = dynamoModule as jest.Mocked<typeof dynamoModule>;
const mockWs = wsModule as jest.Mocked<typeof wsModule>;

// Helper to create a mock async generator for converseStream
function mockConverseStream(chunks: bedrockModule.StreamChunk[]): jest.Mock {
  return jest.fn().mockImplementation(async function* () {
    for (const chunk of chunks) {
      yield chunk;
    }
  });
}

beforeEach(() => {
  jest.clearAllMocks();

  // Default mocks
  mockWs.sendToConnection.mockResolvedValue(true);
  mockDynamo.putPendingToolCall.mockResolvedValue(undefined);
  mockDynamo.deletePendingToolCall.mockResolvedValue(undefined);

  // Mock docClient.send for saveFullConversation
  (mockDynamo as any).docClient = {
    send: jest.fn().mockResolvedValue({}),
  };
  (mockDynamo as any).SESSIONS_TABLE = 'VoiceIDE-Sessions';
});

// ─── handleTranscriptFinal ──────────────────────────────────────────────────

describe('handleTranscriptFinal', () => {
  test('calls converseStream with user message appended', async () => {
    const session: SessionRecord = {
      sessionId: 'sess-1',
      conversation: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    mockDynamo.getOrCreateSession.mockResolvedValue(session);

    // Mock Bedrock to immediately complete (no output)
    const converseStreamMock = mockConverseStream([
      { type: 'complete', stopReason: 'end_turn' },
    ]);
    jest.spyOn(bedrockModule, 'converseStream').mockImplementation(converseStreamMock);

    await handleTranscriptFinal('conn-1', 'sess-1', 'Hello');

    // Verify converseStream was called with the user message
    expect(bedrockModule.converseStream).toHaveBeenCalled();
    const callArgs = (bedrockModule.converseStream as jest.Mock).mock.calls[0];
    const conversation = callArgs[0];
    expect(conversation).toHaveLength(1);
    expect(conversation[0].role).toBe('user');
    expect(conversation[0].content[0].text).toBe('Hello');
  });

  test('forwards tool_call to client and saves pending state', async () => {
    const session: SessionRecord = {
      sessionId: 'sess-1',
      conversation: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    mockDynamo.getOrCreateSession.mockResolvedValue(session);

    // Mock Bedrock to return a tool_call
    const converseStreamMock = jest.fn().mockImplementation(async function* () {
      yield {
        type: 'tool_use' as const,
        toolUseId: 'bedrock-tool-1',
        name: 'tool_call',
        input: {
          name: 'tts.speak',
          arguments: { text: 'Hi there!' },
          call_id: 'app-call-1',
        },
      };
    });

    jest.spyOn(bedrockModule, 'converseStream').mockImplementation(converseStreamMock);

    await handleTranscriptFinal('conn-1', 'sess-1', 'Hello');

    // Should have saved pending tool call
    expect(mockDynamo.putPendingToolCall).toHaveBeenCalledWith(
      'sess-1',
      'app-call-1',
      'tts.speak',
      'bedrock-tool-1',
    );

    // Should have forwarded tool.call to client
    const sendCalls = mockWs.sendToConnection.mock.calls;
    const toolCallEvent = sendCalls.find(
      ([, event]) => 'toolCall' in event.kind,
    );
    expect(toolCallEvent).toBeDefined();
    if (toolCallEvent) {
      const kind = toolCallEvent[1].kind as { toolCall: { name: string; callId: string } };
      expect(kind.toolCall.name).toBe('tts.speak');
      expect(kind.toolCall.callId).toBe('app-call-1');
    }
  });

  test('sends error event when model emits tool_call without inner name', async () => {
    const session: SessionRecord = {
      sessionId: 'sess-1',
      conversation: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    mockDynamo.getOrCreateSession.mockResolvedValue(session);

    const converseStreamMock = jest.fn().mockImplementation(async function* () {
      yield {
        type: 'tool_use' as const,
        toolUseId: 'bedrock-tool-1',
        name: 'tool_call',
        input: { arguments: {}, call_id: 'x' },
        // missing "name" inside input
      };
      yield { type: 'complete' as const, stopReason: 'end_turn' };
    });

    jest.spyOn(bedrockModule, 'converseStream').mockImplementation(converseStreamMock);

    await handleTranscriptFinal('conn-1', 'sess-1', 'Hello');

    const sendCalls = mockWs.sendToConnection.mock.calls;
    const errorEvent = sendCalls.find(([, event]) => 'error' in event.kind);
    expect(errorEvent).toBeDefined();
  });
});

// ─── handleToolResult ───────────────────────────────────────────────────────

describe('handleToolResult', () => {
  test('feeds tool result back to Bedrock and continues conversation', async () => {
    const session: SessionRecord = {
      sessionId: 'sess-1',
      conversation: [
        { role: 'user', content: [{ text: 'Hello' }] },
        {
          role: 'assistant',
          content: [
            {
              toolUse: {
                toolUseId: 'bedrock-tool-1',
                name: 'tool_call',
                input: { name: 'tts.speak', arguments: { text: 'Hi!' }, call_id: 'call-1' },
              },
            },
          ],
        },
      ],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    mockDynamo.getOrCreateSession.mockResolvedValue(session);
    mockDynamo.getPendingToolCall.mockResolvedValue({
      sessionId: 'sess-1',
      pendingCallId: 'call-1',
      pendingToolName: 'tts.speak',
      bedrockToolUseId: 'bedrock-tool-1',
      createdAt: new Date().toISOString(),
      ttl: Math.floor(Date.now() / 1000) + 300,
    });

    // After feeding tool result, model completes with text
    const converseStreamMock = jest.fn().mockImplementation(async function* () {
      yield { type: 'complete' as const, stopReason: 'end_turn' };
    });

    jest.spyOn(bedrockModule, 'converseStream').mockImplementation(converseStreamMock);

    await handleToolResult('conn-1', 'sess-1', 'call-1', '{"spoken":true}', null);

    // Should have cleared pending state
    expect(mockDynamo.deletePendingToolCall).toHaveBeenCalledWith('sess-1');

    // Bedrock should have been called with conversation including toolResult
    expect(bedrockModule.converseStream).toHaveBeenCalled();
  });

  test('sends error when no pending tool call exists', async () => {
    mockDynamo.getPendingToolCall.mockResolvedValue(null);

    await handleToolResult('conn-1', 'sess-1', 'call-1', '{}', null);

    const sendCalls = mockWs.sendToConnection.mock.calls;
    const errorEvent = sendCalls.find(([, event]) => 'error' in event.kind);
    expect(errorEvent).toBeDefined();
    if (errorEvent) {
      const kind = errorEvent[1].kind as { error: { code: string } };
      expect(kind.error.code).toBe('no_pending_tool_call');
    }
  });

  test('handles error tool result from client', async () => {
    const session: SessionRecord = {
      sessionId: 'sess-1',
      conversation: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    mockDynamo.getOrCreateSession.mockResolvedValue(session);
    mockDynamo.getPendingToolCall.mockResolvedValue({
      sessionId: 'sess-1',
      pendingCallId: 'call-1',
      pendingToolName: 'tts.speak',
      bedrockToolUseId: 'bedrock-tool-1',
      createdAt: new Date().toISOString(),
      ttl: Math.floor(Date.now() / 1000) + 300,
    });

    const converseStreamMock = jest.fn().mockImplementation(async function* () {
      yield { type: 'complete' as const, stopReason: 'end_turn' };
    });

    jest.spyOn(bedrockModule, 'converseStream').mockImplementation(converseStreamMock);

    await handleToolResult('conn-1', 'sess-1', 'call-1', null, 'TTS failed');

    // Should still continue (model can handle errors)
    expect(bedrockModule.converseStream).toHaveBeenCalled();
  });
});

import {
  validateWireEvent,
  makeEvent,
  makeToolCallEvent,
  makeSpeechPartialEvent,
  makeSpeechFinalEvent,
  makeErrorEvent,
  isSessionStart,
  isTranscriptFinal,
  isToolResult,
  isToolCall,
  WireEvent,
} from '../src/models/events';

describe('Event Validation', () => {
  test('validates a well-formed sessionStart event', () => {
    const event: WireEvent = {
      id: '550e8400-e29b-41d4-a716-446655440000',
      timestamp: new Date().toISOString(),
      kind: { sessionStart: { sessionId: 'abc-123' } },
    };

    const result = validateWireEvent(event);
    expect(result.valid).toBe(true);
    if (result.valid) {
      expect(result.event.id).toBe(event.id);
    }
  });

  test('validates a well-formed toolCall event', () => {
    const event: WireEvent = {
      id: 'test-id',
      timestamp: new Date().toISOString(),
      kind: {
        toolCall: {
          callId: 'call-1',
          name: 'tts.speak',
          arguments: '{"text":"hello"}',
        },
      },
    };

    const result = validateWireEvent(event);
    expect(result.valid).toBe(true);
  });

  test('validates a well-formed toolResult event', () => {
    const event: WireEvent = {
      id: 'test-id',
      timestamp: new Date().toISOString(),
      kind: {
        toolResult: {
          callId: 'call-1',
          result: '{"spoken":true}',
          error: null,
        },
      },
    };

    const result = validateWireEvent(event);
    expect(result.valid).toBe(true);
  });

  test('rejects null input', () => {
    const result = validateWireEvent(null);
    expect(result.valid).toBe(false);
    if (!result.valid) {
      expect(result.error).toContain('non-null object');
    }
  });

  test('rejects missing id', () => {
    const result = validateWireEvent({
      timestamp: new Date().toISOString(),
      kind: { sessionStart: { sessionId: 'abc' } },
    });
    expect(result.valid).toBe(false);
  });

  test('rejects empty id', () => {
    const result = validateWireEvent({
      id: '',
      timestamp: new Date().toISOString(),
      kind: { sessionStart: { sessionId: 'abc' } },
    });
    expect(result.valid).toBe(false);
  });

  test('rejects missing kind', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
    });
    expect(result.valid).toBe(false);
  });

  test('rejects unknown event kind', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
      kind: { unknownKind: {} },
    });
    expect(result.valid).toBe(false);
    if (!result.valid) {
      expect(result.error).toContain('Unknown event kind');
    }
  });

  test('rejects toolCall with missing callId', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
      kind: {
        toolCall: {
          name: 'tts.speak',
          arguments: '{}',
        },
      },
    });
    expect(result.valid).toBe(false);
  });

  test('rejects toolResult with missing callId', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
      kind: {
        toolResult: {
          result: '{}',
          error: null,
        },
      },
    });
    expect(result.valid).toBe(false);
  });

  test('rejects sessionStart with missing sessionId', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
      kind: {
        sessionStart: {},
      },
    });
    expect(result.valid).toBe(false);
  });

  test('rejects multiple kind keys', () => {
    const result = validateWireEvent({
      id: 'test',
      timestamp: new Date().toISOString(),
      kind: {
        sessionStart: { sessionId: 'abc' },
        error: { code: 'test', message: 'test' },
      },
    });
    expect(result.valid).toBe(false);
    if (!result.valid) {
      expect(result.error).toContain('exactly one key');
    }
  });
});

describe('Event Factories', () => {
  test('makeEvent creates valid event with UUID', () => {
    const event = makeEvent({ sessionStart: { sessionId: 'test' } });
    expect(event.id).toBeTruthy();
    expect(event.timestamp).toBeTruthy();
    expect(isSessionStart(event.kind)).toBe(true);
  });

  test('makeToolCallEvent creates valid tool call', () => {
    const event = makeToolCallEvent('call-1', 'tts.speak', '{"text":"hi"}');
    expect(isToolCall(event.kind)).toBe(true);
    if (isToolCall(event.kind)) {
      expect(event.kind.toolCall.callId).toBe('call-1');
      expect(event.kind.toolCall.name).toBe('tts.speak');
      expect(event.kind.toolCall.arguments).toBe('{"text":"hi"}');
    }
  });

  test('makeSpeechPartialEvent creates valid speech partial', () => {
    const event = makeSpeechPartialEvent('Hello');
    const kind = event.kind as { assistantSpeechPartial: { text: string } };
    expect(kind.assistantSpeechPartial.text).toBe('Hello');
  });

  test('makeSpeechFinalEvent creates valid speech final', () => {
    const event = makeSpeechFinalEvent('Hello world');
    const kind = event.kind as { assistantSpeechFinal: { text: string } };
    expect(kind.assistantSpeechFinal.text).toBe('Hello world');
  });

  test('makeErrorEvent creates valid error', () => {
    const event = makeErrorEvent('test_code', 'test message');
    const kind = event.kind as { error: { code: string; message: string } };
    expect(kind.error.code).toBe('test_code');
    expect(kind.error.message).toBe('test message');
  });
});

describe('Type Guards', () => {
  test('isSessionStart', () => {
    expect(isSessionStart({ sessionStart: { sessionId: 'abc' } })).toBe(true);
    expect(isSessionStart({ error: { code: 'a', message: 'b' } })).toBe(false);
  });

  test('isTranscriptFinal', () => {
    expect(isTranscriptFinal({ userAudioTranscriptFinal: { text: 'hi' } })).toBe(true);
    expect(isTranscriptFinal({ sessionStart: { sessionId: 'a' } })).toBe(false);
  });

  test('isToolResult', () => {
    expect(isToolResult({ toolResult: { callId: 'a', result: '{}', error: null } })).toBe(true);
    expect(isToolResult({ toolCall: { callId: 'a', name: 'b', arguments: '{}' } })).toBe(false);
  });

  test('isToolCall', () => {
    expect(isToolCall({ toolCall: { callId: 'a', name: 'b', arguments: '{}' } })).toBe(true);
    expect(isToolCall({ toolResult: { callId: 'a', result: null, error: null } })).toBe(false);
  });
});

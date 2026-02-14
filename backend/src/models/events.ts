/**
 * VoiceIDE Event Protocol — TypeScript definitions.
 *
 * These mirror the Swift Event model exactly. Every message on the WebSocket
 * is a WireEvent. The "kind" discriminator maps to Swift's Event.Kind enum.
 */

// ─── Wire format (JSON on WebSocket) ───────────────────────────────────────

export interface WireEvent {
  id: string;           // UUID
  timestamp: string;    // ISO-8601
  kind: WireEventKind;
}

export type WireEventKind =
  | { sessionStart: { sessionId: string } }
  | { userAudioTranscriptPartial: { text: string } }
  | { userAudioTranscriptFinal: { text: string } }
  | { assistantSpeechPartial: { text: string } }
  | { assistantSpeechFinal: { text: string } }
  | { assistantUIPatch: { patch: string } }
  | { toolCall: { callId: string; name: string; arguments: string } }
  | { toolResult: { callId: string; result: string | null; error: string | null } }
  | { error: { code: string; message: string } };

// ─── Type guards ────────────────────────────────────────────────────────────

export function isSessionStart(kind: WireEventKind): kind is { sessionStart: { sessionId: string } } {
  return 'sessionStart' in kind;
}

export function isTranscriptFinal(kind: WireEventKind): kind is { userAudioTranscriptFinal: { text: string } } {
  return 'userAudioTranscriptFinal' in kind;
}

export function isToolResult(kind: WireEventKind): kind is { toolResult: { callId: string; result: string | null; error: string | null } } {
  return 'toolResult' in kind;
}

export function isToolCall(kind: WireEventKind): kind is { toolCall: { callId: string; name: string; arguments: string } } {
  return 'toolCall' in kind;
}

export function isError(kind: WireEventKind): kind is { error: { code: string; message: string } } {
  return 'error' in kind;
}

// ─── Factories ──────────────────────────────────────────────────────────────

export function makeEvent(kind: WireEventKind, id?: string): WireEvent {
  return {
    id: id ?? crypto.randomUUID(),
    timestamp: new Date().toISOString(),
    kind,
  };
}

export function makeToolCallEvent(callId: string, name: string, args: string): WireEvent {
  return makeEvent({ toolCall: { callId, name, arguments: args } });
}

export function makeSpeechPartialEvent(text: string): WireEvent {
  return makeEvent({ assistantSpeechPartial: { text } });
}

export function makeSpeechFinalEvent(text: string): WireEvent {
  return makeEvent({ assistantSpeechFinal: { text } });
}

export function makeErrorEvent(code: string, message: string): WireEvent {
  return makeEvent({ error: { code, message } });
}

// ─── Validation ─────────────────────────────────────────────────────────────

const VALID_KIND_KEYS = new Set([
  'sessionStart',
  'userAudioTranscriptPartial',
  'userAudioTranscriptFinal',
  'assistantSpeechPartial',
  'assistantSpeechFinal',
  'assistantUIPatch',
  'toolCall',
  'toolResult',
  'error',
]);

export function validateWireEvent(data: unknown): { valid: true; event: WireEvent } | { valid: false; error: string } {
  if (!data || typeof data !== 'object') {
    return { valid: false, error: 'Event must be a non-null object' };
  }

  const obj = data as Record<string, unknown>;

  if (typeof obj.id !== 'string' || obj.id.length === 0) {
    return { valid: false, error: 'Event must have a non-empty string "id"' };
  }

  if (typeof obj.timestamp !== 'string') {
    return { valid: false, error: 'Event must have a string "timestamp"' };
  }

  if (!obj.kind || typeof obj.kind !== 'object') {
    return { valid: false, error: 'Event must have an object "kind"' };
  }

  const kindKeys = Object.keys(obj.kind as object);
  if (kindKeys.length !== 1) {
    return { valid: false, error: `Event kind must have exactly one key, got: ${kindKeys.join(', ')}` };
  }

  if (!VALID_KIND_KEYS.has(kindKeys[0])) {
    return { valid: false, error: `Unknown event kind: ${kindKeys[0]}` };
  }

  // Validate specific payload shapes
  const kindKey = kindKeys[0];
  const payload = (obj.kind as Record<string, unknown>)[kindKey];

  if (kindKey === 'toolCall') {
    const tc = payload as Record<string, unknown>;
    if (typeof tc.callId !== 'string' || typeof tc.name !== 'string' || typeof tc.arguments !== 'string') {
      return { valid: false, error: 'toolCall must have string callId, name, and arguments' };
    }
  }

  if (kindKey === 'toolResult') {
    const tr = payload as Record<string, unknown>;
    if (typeof tr.callId !== 'string') {
      return { valid: false, error: 'toolResult must have string callId' };
    }
  }

  if (kindKey === 'sessionStart') {
    const ss = payload as Record<string, unknown>;
    if (typeof ss.sessionId !== 'string') {
      return { valid: false, error: 'sessionStart must have string sessionId' };
    }
  }

  return { valid: true, event: obj as unknown as WireEvent };
}

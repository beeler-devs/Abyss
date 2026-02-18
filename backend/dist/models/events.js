"use strict";
/**
 * VoiceIDE Event Protocol — TypeScript definitions.
 *
 * These mirror the Swift Event model exactly. Every message on the WebSocket
 * is a WireEvent. The "kind" discriminator maps to Swift's Event.Kind enum.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.isSessionStart = isSessionStart;
exports.isTranscriptFinal = isTranscriptFinal;
exports.isToolResult = isToolResult;
exports.isToolCall = isToolCall;
exports.isError = isError;
exports.makeEvent = makeEvent;
exports.makeToolCallEvent = makeToolCallEvent;
exports.makeSpeechPartialEvent = makeSpeechPartialEvent;
exports.makeSpeechFinalEvent = makeSpeechFinalEvent;
exports.makeErrorEvent = makeErrorEvent;
exports.validateWireEvent = validateWireEvent;
// ─── Type guards ────────────────────────────────────────────────────────────
function isSessionStart(kind) {
    return 'sessionStart' in kind;
}
function isTranscriptFinal(kind) {
    return 'userAudioTranscriptFinal' in kind;
}
function isToolResult(kind) {
    return 'toolResult' in kind;
}
function isToolCall(kind) {
    return 'toolCall' in kind;
}
function isError(kind) {
    return 'error' in kind;
}
// ─── Factories ──────────────────────────────────────────────────────────────
function makeEvent(kind, id) {
    return {
        id: id ?? crypto.randomUUID(),
        timestamp: new Date().toISOString(),
        kind,
    };
}
function makeToolCallEvent(callId, name, args) {
    return makeEvent({ toolCall: { callId, name, arguments: args } });
}
function makeSpeechPartialEvent(text) {
    return makeEvent({ assistantSpeechPartial: { text } });
}
function makeSpeechFinalEvent(text) {
    return makeEvent({ assistantSpeechFinal: { text } });
}
function makeErrorEvent(code, message) {
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
function validateWireEvent(data) {
    if (!data || typeof data !== 'object') {
        return { valid: false, error: 'Event must be a non-null object' };
    }
    const obj = data;
    if (typeof obj.id !== 'string' || obj.id.length === 0) {
        return { valid: false, error: 'Event must have a non-empty string "id"' };
    }
    if (typeof obj.timestamp !== 'string') {
        return { valid: false, error: 'Event must have a string "timestamp"' };
    }
    if (!obj.kind || typeof obj.kind !== 'object') {
        return { valid: false, error: 'Event must have an object "kind"' };
    }
    const kindKeys = Object.keys(obj.kind);
    if (kindKeys.length !== 1) {
        return { valid: false, error: `Event kind must have exactly one key, got: ${kindKeys.join(', ')}` };
    }
    if (!VALID_KIND_KEYS.has(kindKeys[0])) {
        return { valid: false, error: `Unknown event kind: ${kindKeys[0]}` };
    }
    // Validate specific payload shapes
    const kindKey = kindKeys[0];
    const payload = obj.kind[kindKey];
    if (kindKey === 'toolCall') {
        const tc = payload;
        if (typeof tc.callId !== 'string' || typeof tc.name !== 'string' || typeof tc.arguments !== 'string') {
            return { valid: false, error: 'toolCall must have string callId, name, and arguments' };
        }
    }
    if (kindKey === 'toolResult') {
        const tr = payload;
        if (typeof tr.callId !== 'string') {
            return { valid: false, error: 'toolResult must have string callId' };
        }
    }
    if (kindKey === 'sessionStart') {
        const ss = payload;
        if (typeof ss.sessionId !== 'string') {
            return { valid: false, error: 'sessionStart must have string sessionId' };
        }
    }
    return { valid: true, event: obj };
}
//# sourceMappingURL=events.js.map
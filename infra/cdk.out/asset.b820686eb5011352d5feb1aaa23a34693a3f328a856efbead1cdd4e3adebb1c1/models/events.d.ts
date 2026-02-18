/**
 * VoiceIDE Event Protocol — TypeScript definitions.
 *
 * These mirror the Swift Event model exactly. Every message on the WebSocket
 * is a WireEvent. The "kind" discriminator maps to Swift's Event.Kind enum.
 */
export interface WireEvent {
    id: string;
    timestamp: string;
    kind: WireEventKind;
}
export type WireEventKind = {
    sessionStart: {
        sessionId: string;
    };
} | {
    userAudioTranscriptPartial: {
        text: string;
    };
} | {
    userAudioTranscriptFinal: {
        text: string;
    };
} | {
    assistantSpeechPartial: {
        text: string;
    };
} | {
    assistantSpeechFinal: {
        text: string;
    };
} | {
    assistantUIPatch: {
        patch: string;
    };
} | {
    toolCall: {
        callId: string;
        name: string;
        arguments: string;
    };
} | {
    toolResult: {
        callId: string;
        result: string | null;
        error: string | null;
    };
} | {
    error: {
        code: string;
        message: string;
    };
};
export declare function isSessionStart(kind: WireEventKind): kind is {
    sessionStart: {
        sessionId: string;
    };
};
export declare function isTranscriptFinal(kind: WireEventKind): kind is {
    userAudioTranscriptFinal: {
        text: string;
    };
};
export declare function isToolResult(kind: WireEventKind): kind is {
    toolResult: {
        callId: string;
        result: string | null;
        error: string | null;
    };
};
export declare function isToolCall(kind: WireEventKind): kind is {
    toolCall: {
        callId: string;
        name: string;
        arguments: string;
    };
};
export declare function isError(kind: WireEventKind): kind is {
    error: {
        code: string;
        message: string;
    };
};
export declare function makeEvent(kind: WireEventKind, id?: string): WireEvent;
export declare function makeToolCallEvent(callId: string, name: string, args: string): WireEvent;
export declare function makeSpeechPartialEvent(text: string): WireEvent;
export declare function makeSpeechFinalEvent(text: string): WireEvent;
export declare function makeErrorEvent(code: string, message: string): WireEvent;
export declare function validateWireEvent(data: unknown): {
    valid: true;
    event: WireEvent;
} | {
    valid: false;
    error: string;
};
//# sourceMappingURL=events.d.ts.map
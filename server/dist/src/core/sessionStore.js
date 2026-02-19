import { SlidingWindowRateLimiter } from "./rateLimiter.js";
export class SessionStore {
    sessions = new Map();
    maxTurns;
    rateLimitPerMinute;
    constructor(maxTurns, rateLimitPerMinute) {
        this.maxTurns = maxTurns;
        this.rateLimitPerMinute = rateLimitPerMinute;
    }
    getOrCreate(sessionId) {
        const existing = this.sessions.get(sessionId);
        if (existing) {
            return existing;
        }
        const created = {
            sessionId,
            history: [],
            pendingToolCalls: new Map(),
            toolResultResolvers: new Map(),
            recentTranscriptTrace: [],
            transcriptCount: 0,
        };
        this.sessions.set(sessionId, created);
        return created;
    }
    appendTurn(state, turn) {
        state.history.push(turn);
        const maxEntries = this.maxTurns * 2;
        if (state.history.length > maxEntries) {
            state.history = state.history.slice(-maxEntries);
        }
    }
    recordTrace(state, marker) {
        state.recentTranscriptTrace.push(marker);
        if (state.recentTranscriptTrace.length > 24) {
            state.recentTranscriptTrace.shift();
        }
    }
    createRateLimiter() {
        return new SlidingWindowRateLimiter(this.rateLimitPerMinute, 60_000);
    }
}

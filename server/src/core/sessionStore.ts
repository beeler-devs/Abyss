import { SlidingWindowRateLimiter } from "./rateLimiter.js";
import { ConversationTurn, SessionState } from "./types.js";

export class SessionStore {
  private readonly sessions = new Map<string, SessionState>();
  private readonly maxTurns: number;
  private readonly rateLimitPerMinute: number;

  constructor(maxTurns: number, rateLimitPerMinute: number) {
    this.maxTurns = maxTurns;
    this.rateLimitPerMinute = rateLimitPerMinute;
  }

  getOrCreate(sessionId: string): SessionState {
    const existing = this.sessions.get(sessionId);
    if (existing) {
      return existing;
    }

    const created: SessionState = {
      sessionId,
      history: [],
      pendingToolCalls: new Map(),
      recentTranscriptTrace: [],
      transcriptCount: 0,
    };

    this.sessions.set(sessionId, created);
    return created;
  }

  appendTurn(state: SessionState, turn: ConversationTurn): void {
    state.history.push(turn);

    const maxEntries = this.maxTurns * 2;
    if (state.history.length > maxEntries) {
      state.history = state.history.slice(-maxEntries);
    }
  }

  recordTrace(state: SessionState, marker: string): void {
    state.recentTranscriptTrace.push(marker);
    if (state.recentTranscriptTrace.length > 24) {
      state.recentTranscriptTrace.shift();
    }
  }

  createRateLimiter(): SlidingWindowRateLimiter {
    return new SlidingWindowRateLimiter(this.rateLimitPerMinute, 60_000);
  }
}

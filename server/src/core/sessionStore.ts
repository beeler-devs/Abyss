import { SlidingWindowRateLimiter } from "./rateLimiter.js";
import {
  ConversationTurn,
  CursorAgentRunRecord,
  PendingCursorWebhookRecord,
  SessionState,
} from "./types.js";

export class SessionStore {
  private readonly sessions = new Map<string, SessionState>();
  private readonly cursorRunsByAgentId = new Map<string, CursorAgentRunRecord>();
  private readonly cursorAgentBySpawnCallId = new Map<string, string>();
  private readonly pendingCursorWebhooks = new Map<string, PendingCursorWebhookRecord>();
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
      toolResultResolvers: new Map(),
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

  upsertCursorRun(partial: CursorAgentRunRecord): CursorAgentRunRecord {
    const existing = this.cursorRunsByAgentId.get(partial.agentId);
    const merged: CursorAgentRunRecord = {
      agentId: partial.agentId,
      sessionId: partial.sessionId || existing?.sessionId || "",
      createdAt: partial.createdAt || existing?.createdAt || new Date().toISOString(),
      mode: partial.mode || existing?.mode || "code",
      status: partial.status ?? existing?.status,
      prUrl: partial.prUrl ?? existing?.prUrl,
      runUrl: partial.runUrl ?? existing?.runUrl,
      branchName: partial.branchName ?? existing?.branchName,
      summary: partial.summary ?? existing?.summary,
      spawnCallId: partial.spawnCallId ?? existing?.spawnCallId,
      lastSeenConversationMessageId: partial.lastSeenConversationMessageId ?? existing?.lastSeenConversationMessageId,
    };

    if (merged.spawnCallId) {
      this.cursorAgentBySpawnCallId.set(merged.spawnCallId, merged.agentId);
    }

    this.cursorRunsByAgentId.set(merged.agentId, merged);
    return merged;
  }

  getCursorRun(agentId: string): CursorAgentRunRecord | undefined {
    return this.cursorRunsByAgentId.get(agentId);
  }

  getSessionIdForAgent(agentId: string): string | undefined {
    return this.cursorRunsByAgentId.get(agentId)?.sessionId;
  }

  setSpawnCallAgent(spawnCallId: string, agentId: string): void {
    this.cursorAgentBySpawnCallId.set(spawnCallId, agentId);
  }

  getAgentIdForSpawnCall(spawnCallId: string): string | undefined {
    return this.cursorAgentBySpawnCallId.get(spawnCallId);
  }

  storePendingWebhook(
    agentId: string,
    payload: Record<string, unknown>,
    ttlMs: number,
    nowMs: number = Date.now(),
  ): PendingCursorWebhookRecord {
    this.prunePendingWebhooks(nowMs);
    const record: PendingCursorWebhookRecord = {
      agentId,
      payload,
      receivedAt: new Date(nowMs).toISOString(),
      expiresAtMs: nowMs + ttlMs,
    };
    this.pendingCursorWebhooks.set(agentId, record);
    return record;
  }

  takePendingWebhook(agentId: string, nowMs: number = Date.now()): PendingCursorWebhookRecord | undefined {
    this.prunePendingWebhooks(nowMs);
    const pending = this.pendingCursorWebhooks.get(agentId);
    if (!pending) {
      return undefined;
    }
    this.pendingCursorWebhooks.delete(agentId);
    return pending;
  }

  prunePendingWebhooks(nowMs: number = Date.now()): void {
    for (const [agentId, record] of this.pendingCursorWebhooks.entries()) {
      if (record.expiresAtMs <= nowMs) {
        this.pendingCursorWebhooks.delete(agentId);
      }
    }
  }
}

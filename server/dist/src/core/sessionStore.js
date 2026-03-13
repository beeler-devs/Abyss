import { SlidingWindowRateLimiter } from "./rateLimiter.js";
export class SessionStore {
    sessions = new Map();
    cursorRunsByAgentId = new Map();
    cursorAgentBySpawnCallId = new Map();
    pendingCursorWebhooks = new Map();
    maxTurns;
    rateLimitPerMinute;
    traceMaxEntries;
    constructor(maxTurns, rateLimitPerMinute, traceMaxEntries = 120) {
        this.maxTurns = maxTurns;
        this.rateLimitPerMinute = rateLimitPerMinute;
        this.traceMaxEntries = Math.max(1, traceMaxEntries);
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
        // Each logical turn can produce up to 2 entries (user + assistant, or
        // assistant tool-use + tool result), so the maximum history length is
        // maxTurns * 2.  Keep only the most recent entries to bound memory.
        const maxEntries = this.maxTurns * 2;
        if (state.history.length > maxEntries) {
            state.history = state.history.slice(-maxEntries);
        }
    }
    recordTrace(state, marker) {
        state.recentTranscriptTrace.push(marker);
        if (state.recentTranscriptTrace.length > this.traceMaxEntries * 2) {
            state.recentTranscriptTrace = state.recentTranscriptTrace.slice(-this.traceMaxEntries);
        }
    }
    createRateLimiter() {
        return new SlidingWindowRateLimiter(this.rateLimitPerMinute, 60_000);
    }
    upsertCursorRun(partial) {
        const existing = this.cursorRunsByAgentId.get(partial.agentId);
        const merged = {
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
    getCursorRun(agentId) {
        return this.cursorRunsByAgentId.get(agentId);
    }
    getSessionIdForAgent(agentId) {
        return this.cursorRunsByAgentId.get(agentId)?.sessionId;
    }
    setSpawnCallAgent(spawnCallId, agentId) {
        this.cursorAgentBySpawnCallId.set(spawnCallId, agentId);
    }
    getAgentIdForSpawnCall(spawnCallId) {
        return this.cursorAgentBySpawnCallId.get(spawnCallId);
    }
    storePendingWebhook(agentId, payload, ttlMs, nowMs = Date.now()) {
        this.prunePendingWebhooks(nowMs);
        const record = {
            agentId,
            payload,
            receivedAt: new Date(nowMs).toISOString(),
            expiresAtMs: nowMs + ttlMs,
        };
        this.pendingCursorWebhooks.set(agentId, record);
        return record;
    }
    takePendingWebhook(agentId, nowMs = Date.now()) {
        this.prunePendingWebhooks(nowMs);
        const pending = this.pendingCursorWebhooks.get(agentId);
        if (!pending) {
            return undefined;
        }
        this.pendingCursorWebhooks.delete(agentId);
        return pending;
    }
    prunePendingWebhooks(nowMs = Date.now()) {
        for (const [agentId, record] of this.pendingCursorWebhooks.entries()) {
            if (record.expiresAtMs <= nowMs) {
                this.pendingCursorWebhooks.delete(agentId);
            }
        }
    }
}

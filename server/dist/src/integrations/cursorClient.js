import { normalizeMode, parseCursorAgentSnapshot } from "./cursorPayload.js";
export class CursorClient {
    apiKey;
    webhookUrl;
    webhookSecret;
    baseURL;
    timeoutMs;
    constructor(config) {
        this.apiKey = config.apiKey?.trim() ?? "";
        this.webhookUrl = config.webhookUrl?.trim() || undefined;
        this.webhookSecret = config.webhookSecret?.trim() || undefined;
        this.baseURL = (config.baseURL?.trim() || "https://api.cursor.com").replace(/\/+$/, "");
        this.timeoutMs = config.timeoutMs ?? 30_000;
    }
    isConfigured() {
        return this.apiKey.length > 0;
    }
    hasWebhookConfig() {
        return Boolean(this.webhookUrl && this.webhookSecret);
    }
    async spawnAgent(input) {
        this.assertConfigured();
        const prompt = input.prompt.trim();
        if (!prompt) {
            throw new Error("cursor_invalid_prompt");
        }
        const mode = input.mode ?? normalizeMode(asString(input.metadata?.mode)) ?? "code";
        const metadata = { ...(input.metadata ?? {}), mode };
        const source = {};
        if (input.repoUrl?.trim()) {
            source.repository = input.repoUrl.trim();
        }
        if (input.ref?.trim()) {
            source.ref = input.ref.trim();
        }
        if (input.prUrl?.trim()) {
            source.prUrl = input.prUrl.trim();
        }
        const body = {
            prompt: { text: prompt },
            source,
            metadata,
        };
        if (this.webhookUrl && this.webhookSecret) {
            body.webhook = {
                url: this.webhookUrl,
                secret: this.webhookSecret,
            };
        }
        const payload = await this.requestJSON("POST", "/v0/agents", body);
        return this.toStatusResult(payload);
    }
    async status(agentId) {
        this.assertConfigured();
        const normalizedAgentId = this.normalizeAgentId(agentId);
        const payload = await this.requestJSON("GET", `/v0/agents/${encodeURIComponent(normalizedAgentId)}`);
        return this.toStatusResult(payload);
    }
    async followup(agentId, message) {
        this.assertConfigured();
        const normalizedAgentId = this.normalizeAgentId(agentId);
        const prompt = message.trim();
        if (!prompt) {
            throw new Error("cursor_invalid_followup");
        }
        await this.requestJSON("POST", `/v0/agents/${encodeURIComponent(normalizedAgentId)}/followup`, {
            prompt: { text: prompt },
        });
    }
    async cancel(agentId) {
        this.assertConfigured();
        const normalizedAgentId = this.normalizeAgentId(agentId);
        await this.requestJSON("POST", `/v0/agents/${encodeURIComponent(normalizedAgentId)}/stop`);
    }
    async conversation(agentId) {
        this.assertConfigured();
        const normalizedAgentId = this.normalizeAgentId(agentId);
        const payload = await this.requestJSON("GET", `/v0/agents/${encodeURIComponent(normalizedAgentId)}/conversation`);
        const messages = Array.isArray(payload.messages)
            ? payload.messages.flatMap((msg) => {
                const id = asString(msg.id);
                const type = asString(msg.type);
                const text = asString(msg.text);
                if (!id || !type || !text)
                    return [];
                if (type !== "user_message" && type !== "assistant_message")
                    return [];
                return [{ id, type: type, text }];
            })
            : [];
        return {
            id: asString(payload.id) ?? normalizedAgentId,
            messages,
        };
    }
    async repositories() {
        this.assertConfigured();
        const payload = await this.requestJSON("GET", "/v0/repositories");
        const repositoriesRaw = payload.repositories;
        if (!Array.isArray(repositoriesRaw)) {
            return [];
        }
        return repositoriesRaw.flatMap((value) => {
            if (!value || typeof value !== "object" || Array.isArray(value)) {
                return [];
            }
            const record = value;
            const repository = asString(record.repository);
            if (!repository) {
                return [];
            }
            return [{
                    repository,
                    owner: asString(record.owner),
                    name: asString(record.name),
                }];
        });
    }
    async requestJSON(method, path, body) {
        const request = new Request(`${this.baseURL}${path}`, {
            method,
            headers: {
                "Authorization": `Basic ${Buffer.from(`${this.apiKey}:`, "utf8").toString("base64")}`,
                "Accept": "application/json",
                ...(body ? { "Content-Type": "application/json" } : {}),
            },
            body: body ? JSON.stringify(body) : undefined,
            signal: AbortSignal.timeout(this.timeoutMs),
        });
        const response = await fetch(request);
        const raw = await response.text();
        const parsed = safeParseJSON(raw);
        if (!response.ok) {
            const errorPayload = parsed;
            const message = errorPayload?.error ?? errorPayload?.message ?? raw.slice(0, 240);
            throw new Error(`cursor_http_${response.status}:${message}`);
        }
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            throw new Error("cursor_invalid_json_response");
        }
        return parsed;
    }
    toStatusResult(payload) {
        const snapshot = parseCursorAgentSnapshot(payload);
        if (!snapshot) {
            throw new Error("cursor_missing_agent_id");
        }
        return this.fromSnapshot(snapshot);
    }
    fromSnapshot(snapshot) {
        return {
            agentId: snapshot.agentId,
            status: snapshot.status,
            runUrl: snapshot.runUrl,
            prUrl: snapshot.prUrl,
            branchName: snapshot.branchName,
            summary: snapshot.summary,
        };
    }
    normalizeAgentId(agentId) {
        const normalized = agentId.trim();
        if (!normalized) {
            throw new Error("cursor_missing_agent_id");
        }
        return normalized;
    }
    assertConfigured() {
        if (!this.isConfigured()) {
            throw new Error("cursor_server_not_configured");
        }
    }
}
function safeParseJSON(raw) {
    try {
        return JSON.parse(raw);
    }
    catch {
        return null;
    }
}
function asString(value) {
    if (typeof value !== "string") {
        return undefined;
    }
    const trimmed = value.trim();
    return trimmed.length ? trimmed : undefined;
}

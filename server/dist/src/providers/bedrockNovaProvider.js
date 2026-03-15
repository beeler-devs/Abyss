import { BedrockRuntimeClient, ConverseCommand, } from "@aws-sdk/client-bedrock-runtime";
import { chunkText, streamFromChunks } from "./chunking.js";
function asNonEmptyString(value) {
    if (typeof value !== "string") {
        return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? value : null;
}
function tryParseJSONObject(value) {
    try {
        const parsed = JSON.parse(value);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
            return parsed;
        }
    }
    catch {
        // Ignore invalid JSON and fall back to plain text tool results.
    }
    return null;
}
export class BedrockNovaProvider {
    name = "bedrock";
    config;
    client;
    bearerToken;
    constructor(config, client) {
        this.config = config;
        this.bearerToken = process.env.AWS_BEARER_TOKEN_BEDROCK || undefined;
        this.client = client ?? new BedrockRuntimeClient({ region: config.region });
    }
    async generateResponse(conversation, tools) {
        const { fullText, toolCalls } = await this.fetchResponse(conversation, tools);
        const chunks = chunkText(fullText, 30, 80);
        const response = {
            fullText,
            chunks: streamFromChunks(chunks.length ? chunks : [fullText], this.config.partialDelayMs),
        };
        if (toolCalls.length > 0) {
            response.toolCalls = toolCalls;
        }
        return response;
    }
    buildSystemPrompt() {
        return [{
                text: [
                    "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
                    "Keep spoken responses concise, practical, and voice-friendly.",
                    "Do not ask for speech-to-text tools. The user triggers listening manually.",
                    "Avoid markdown tables and avoid long formatting.",
                    "If webqa.cursor.run is available and the user asks to validate behavior in a browser, call webqa.cursor.run.",
                    "If cursor.agent.spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor.agent.spawn.",
                    "When using cursor.agent.spawn or webqa.cursor.run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
                    "If cursor.agent.spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent.spawn.",
                    "When using legacy agent.spawn for repo work, if you do not know the exact owner/repo string, call repositories.list first.",
                    "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
                    "Never guess or hallucinate a repository name. Only use repos returned by repositories.list.",
                    "If gmail.inbox, gmail.search, gmail.read, gmail.send, or gmail.reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
                    "For gmail.search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
                    "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail.send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
                    "Similarly for gmail.reply — draft the reply body and call gmail.reply immediately. The app handles confirmation via a card.",
                    "If gmail tools are NOT available but gmail.authenticate IS available, call gmail.authenticate when the user asks about email — this opens the sign-in screen on their device.",
                ].join(" "),
            }];
    }
    buildMessages(conversation) {
        const resolvedToolUseIds = new Set();
        for (const turn of conversation) {
            if (turn.role === "tool" && turn.tool_use_id) {
                resolvedToolUseIds.add(turn.tool_use_id);
            }
        }
        const skippedToolUseIds = new Set();
        for (const turn of conversation) {
            if (turn.role === "assistant" && Array.isArray(turn.content)) {
                for (const toolCall of turn.content) {
                    if (!resolvedToolUseIds.has(toolCall.id)) {
                        skippedToolUseIds.add(toolCall.id);
                    }
                }
            }
        }
        const messages = [];
        let pendingToolResults = [];
        const flushToolResults = () => {
            if (pendingToolResults.length === 0) {
                return;
            }
            messages.push({
                role: "user",
                content: pendingToolResults.map((toolResult) => ({ toolResult })),
            });
            pendingToolResults = [];
        };
        for (const turn of conversation) {
            if (turn.role === "system") {
                continue;
            }
            if (turn.role === "tool") {
                const toolUseId = asNonEmptyString(turn.tool_use_id);
                const textContent = typeof turn.content === "string"
                    ? turn.content
                    : JSON.stringify(turn.content);
                if (!toolUseId) {
                    flushToolResults();
                    messages.push({
                        role: "user",
                        content: [{ text: textContent }],
                    });
                    continue;
                }
                if (skippedToolUseIds.has(toolUseId)) {
                    continue;
                }
                const jsonResult = tryParseJSONObject(textContent);
                pendingToolResults.push({
                    toolUseId,
                    status: textContent.startsWith("Error:") ? "error" : "success",
                    content: jsonResult
                        ? [{ json: jsonResult }]
                        : [{ text: textContent }],
                });
                continue;
            }
            flushToolResults();
            if (turn.role === "assistant" && Array.isArray(turn.content)) {
                const resolved = turn.content.filter((toolCall) => !skippedToolUseIds.has(toolCall.id));
                if (resolved.length === 0) {
                    continue;
                }
                messages.push({
                    role: "assistant",
                    content: resolved.map((toolCall) => ({
                        toolUse: {
                            toolUseId: toolCall.id,
                            name: toolCall.name.replace(/\./g, "_"),
                            input: toolCall.input,
                        },
                    })),
                });
                continue;
            }
            if ((turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string") {
                messages.push({
                    role: turn.role,
                    content: [{ text: turn.content }],
                });
            }
        }
        flushToolResults();
        while (messages.length > 0 && messages[0]?.role !== "user") {
            messages.shift();
        }
        return messages;
    }
    buildTools(tools) {
        const toolNameToOriginal = new Map();
        const toolSpecs = (tools ?? [])
            .filter((tool) => Boolean(tool.name))
            .map((tool) => {
            const safeName = tool.name.replace(/\./g, "_");
            if (safeName !== tool.name) {
                toolNameToOriginal.set(safeName, tool.name);
            }
            return {
                toolSpec: {
                    name: safeName,
                    description: tool.description,
                    inputSchema: {
                        json: tool.input_schema,
                    },
                },
            };
        });
        return {
            toolConfig: toolSpecs.length > 0 ? { tools: toolSpecs } : undefined,
            toolNameToOriginal,
        };
    }
    async fetchResponse(conversation, tools) {
        const messages = this.buildMessages(conversation);
        const { toolConfig, toolNameToOriginal } = this.buildTools(tools);
        const maxTokens = toolConfig ? Math.min(this.config.maxTokens * 4, 8192) : this.config.maxTokens;
        const contentBlocks = this.bearerToken
            ? await this.fetchWithBearer(messages, toolConfig, maxTokens)
            : await this.fetchWithSdk(messages, toolConfig, maxTokens);
        const textParts = [];
        const toolCalls = [];
        for (const block of contentBlocks) {
            if (typeof block.text === "string") {
                textParts.push(block.text);
            }
            const toolUseId = asNonEmptyString(block.toolUse?.toolUseId);
            const toolName = asNonEmptyString(block.toolUse?.name);
            const toolInput = block.toolUse?.input;
            if (toolUseId && toolName && toolInput && typeof toolInput === "object" && !Array.isArray(toolInput)) {
                toolCalls.push({
                    id: toolUseId,
                    name: toolNameToOriginal.get(toolName) ?? toolName,
                    input: toolInput,
                });
            }
        }
        return {
            fullText: textParts.join("").trim(),
            toolCalls,
        };
    }
    async fetchWithSdk(messages, toolConfig, maxTokens) {
        const response = await this.client.send(new ConverseCommand({
            modelId: this.config.modelId,
            system: this.buildSystemPrompt(),
            messages,
            inferenceConfig: { maxTokens, temperature: 0.3 },
            ...(toolConfig ? { toolConfig } : {}),
        }));
        return (response.output?.message?.content ?? []);
    }
    async fetchWithBearer(messages, toolConfig, maxTokens) {
        const url = `https://bedrock-runtime.${this.config.region}.amazonaws.com/model/${encodeURIComponent(this.config.modelId)}/converse`;
        const body = {
            system: this.buildSystemPrompt().map((b) => ({ text: b.text })),
            messages: messages.map((m) => ({
                role: m.role,
                content: m.content?.map((c) => {
                    if ("text" in c && c.text)
                        return { text: c.text };
                    if ("toolUse" in c && c.toolUse)
                        return { toolUse: c.toolUse };
                    if ("toolResult" in c && c.toolResult)
                        return { toolResult: c.toolResult };
                    return c;
                }),
            })),
            inferenceConfig: { maxTokens, temperature: 0.3 },
        };
        if (toolConfig) {
            body.toolConfig = toolConfig;
        }
        const res = await fetch(url, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${this.bearerToken}`,
            },
            body: JSON.stringify(body),
        });
        if (!res.ok) {
            const errorText = await res.text();
            throw new Error(`Bedrock API error ${res.status}: ${errorText}`);
        }
        const json = (await res.json());
        const output = json.output;
        const message = output?.message;
        return (message?.content ?? []);
    }
}

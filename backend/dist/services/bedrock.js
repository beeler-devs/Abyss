"use strict";
/**
 * Amazon Bedrock ConverseStream integration.
 *
 * Calls the Bedrock Converse API with streaming, using the tool_call
 * bridging pattern: we define a single "tool_call" tool that the model
 * uses to request client-side tool execution.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.TOOL_CONFIG = exports.SYSTEM_PROMPT = void 0;
exports.initBedrockClient = initBedrockClient;
exports.getBedrockClient = getBedrockClient;
exports.setBedrockClient = setBedrockClient;
exports.getModelId = getModelId;
exports.converseStream = converseStream;
const client_bedrock_runtime_1 = require("@aws-sdk/client-bedrock-runtime");
const logger_1 = require("../utils/logger");
// ─── Client ─────────────────────────────────────────────────────────────────
let bedrockClient = null;
function initBedrockClient(region) {
    bedrockClient = new client_bedrock_runtime_1.BedrockRuntimeClient({
        region: region || process.env.AWS_REGION || 'us-east-1',
    });
}
function getBedrockClient() {
    if (!bedrockClient) {
        initBedrockClient();
    }
    return bedrockClient;
}
/** For testing injection. */
function setBedrockClient(client) {
    bedrockClient = client;
}
// ─── Model configuration ───────────────────────────────────────────────────
function getModelId() {
    return process.env.BEDROCK_MODEL_ID || 'amazon.nova-lite-v1:0';
}
// ─── System prompt ──────────────────────────────────────────────────────────
exports.SYSTEM_PROMPT = `You are VoiceIDE, a helpful voice assistant. You operate exclusively through tool calls — never produce side effects directly.

RULES:
1. For EVERY response, you MUST use the tool_call tool to execute actions.
2. To speak to the user, emit: tool_call with name="tts.speak" and arguments={"text": "your spoken response"}.
3. To append messages to the conversation log, emit: tool_call with name="convo.appendMessage" and arguments={"role": "user"|"assistant", "text": "...", "isPartial": false}.
4. To change app state, emit: tool_call with name="convo.setState" and arguments={"state": "thinking"|"speaking"|"idle"}.
5. NEVER request stt.start or stt.stop — those are user-driven.
6. Keep spoken text concise and voice-friendly (short sentences, no markdown).
7. Always follow this sequence for a response:
   a. tool_call convo.setState {state: "thinking"}
   b. tool_call convo.appendMessage {role: "user", text: <user's transcript>}
   c. tool_call convo.appendMessage {role: "assistant", text: <your response text>}
   d. tool_call convo.setState {state: "speaking"}
   e. tool_call tts.speak {text: <your response text>}
   f. tool_call convo.setState {state: "idle"}
8. Use a friendly, conversational voice style. Be helpful and concise.
9. If you are unsure, say so honestly. Do not make up information.`;
// ─── Tool configuration ────────────────────────────────────────────────────
/**
 * We define a single Bedrock tool "tool_call" that wraps all client-side tools.
 * The model emits tool_call requests with {name, arguments, call_id} to invoke
 * specific client tools. The backend forwards these to the iOS client.
 */
exports.TOOL_CONFIG = {
    tools: [
        {
            toolSpec: {
                name: 'tool_call',
                description: 'Execute a tool on the client device. Available tools: ' +
                    'tts.speak (speak text aloud), tts.stop (stop speaking), ' +
                    'convo.appendMessage (add message to conversation), ' +
                    'convo.setState (change app state to: idle, thinking, speaking). ' +
                    'Always use this tool for all actions.',
                inputSchema: {
                    json: {
                        type: 'object',
                        properties: {
                            name: {
                                type: 'string',
                                description: 'The tool name to invoke (e.g., "tts.speak", "convo.setState", "convo.appendMessage")',
                            },
                            arguments: {
                                type: 'object',
                                description: 'The arguments for the tool, as a JSON object',
                            },
                            call_id: {
                                type: 'string',
                                description: 'A unique identifier for this tool call',
                            },
                        },
                        required: ['name', 'arguments', 'call_id'],
                    },
                },
            },
        },
    ],
};
// ─── Convert internal messages to Bedrock format ────────────────────────────
function toBedrockMessages(messages) {
    return messages.map((msg) => ({
        role: msg.role,
        content: msg.content.map((block) => {
            if ('text' in block) {
                return { text: block.text };
            }
            if ('toolUse' in block) {
                return {
                    toolUse: {
                        toolUseId: block.toolUse.toolUseId,
                        name: block.toolUse.name,
                        input: block.toolUse.input,
                    },
                };
            }
            if ('toolResult' in block) {
                return {
                    toolResult: {
                        toolUseId: block.toolResult.toolUseId,
                        content: block.toolResult.content.map((c) => ({ text: c.text })),
                        status: block.toolResult.status || 'success',
                    },
                };
            }
            return { text: '' };
        }),
    }));
}
// ─── ConverseStream call ────────────────────────────────────────────────────
/**
 * Call Bedrock ConverseStream and yield chunks as they arrive.
 * This is an async generator that yields StreamChunk objects.
 */
async function* converseStream(conversation, sessionId) {
    const client = getBedrockClient();
    const modelId = getModelId();
    const systemPrompt = [{ text: exports.SYSTEM_PROMPT }];
    const messages = toBedrockMessages(conversation);
    // Ensure conversation starts with a user message
    if (messages.length === 0 || messages[0].role !== 'user') {
        logger_1.logger.warn('Conversation does not start with user message', { sessionId });
    }
    const input = {
        modelId,
        system: systemPrompt,
        messages,
        toolConfig: exports.TOOL_CONFIG,
        inferenceConfig: {
            maxTokens: 2048,
            temperature: 0.7,
            topP: 0.9,
        },
    };
    logger_1.logger.info('Calling Bedrock ConverseStream', { sessionId }, {
        modelId,
        messageCount: messages.length,
    });
    try {
        const command = new client_bedrock_runtime_1.ConverseStreamCommand(input);
        const response = await client.send(command);
        if (!response.stream) {
            yield { type: 'error', message: 'No stream in Bedrock response' };
            return;
        }
        let currentToolUseId = '';
        let currentToolName = '';
        let toolInputJson = '';
        let textBuffer = '';
        for await (const chunk of response.stream) {
            // Text content
            if (chunk.contentBlockDelta?.delta?.text) {
                const text = chunk.contentBlockDelta.delta.text;
                textBuffer += text;
                yield { type: 'text_delta', text };
            }
            // Tool use start
            if (chunk.contentBlockStart?.start?.toolUse) {
                const toolUse = chunk.contentBlockStart.start.toolUse;
                currentToolUseId = toolUse.toolUseId || '';
                currentToolName = toolUse.name || '';
                toolInputJson = '';
            }
            // Tool use input delta
            if (chunk.contentBlockDelta?.delta?.toolUse) {
                toolInputJson += chunk.contentBlockDelta.delta.toolUse.input || '';
            }
            // Content block stop — if we were building a tool use, emit it
            if (chunk.contentBlockStop !== undefined) {
                if (currentToolUseId && currentToolName) {
                    try {
                        const parsedInput = JSON.parse(toolInputJson || '{}');
                        yield {
                            type: 'tool_use',
                            toolUseId: currentToolUseId,
                            name: currentToolName,
                            input: parsedInput,
                        };
                    }
                    catch (parseErr) {
                        logger_1.logger.error('Failed to parse tool input JSON', { sessionId }, {
                            toolUseId: currentToolUseId,
                            rawInput: toolInputJson,
                        });
                        yield {
                            type: 'error',
                            message: `Invalid tool input JSON: ${toolInputJson}`,
                        };
                    }
                    currentToolUseId = '';
                    currentToolName = '';
                    toolInputJson = '';
                }
            }
            // Stream complete with metadata
            if (chunk.messageStop) {
                yield {
                    type: 'complete',
                    stopReason: chunk.messageStop.stopReason || 'end_turn',
                };
            }
        }
    }
    catch (err) {
        const message = err.message || 'Unknown Bedrock error';
        logger_1.logger.error('Bedrock ConverseStream failed', { sessionId }, { error: message });
        yield { type: 'error', message };
    }
}
//# sourceMappingURL=bedrock.js.map
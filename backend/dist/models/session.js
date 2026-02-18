"use strict";
/**
 * Session and conversation models for DynamoDB persistence.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.PENDING_TOOL_CALL_TTL = exports.MAX_CONVERSATION_TURNS = void 0;
// ─── Constants ──────────────────────────────────────────────────────────────
/** Maximum number of conversation turns to keep (bounded growth). */
exports.MAX_CONVERSATION_TURNS = 50;
/** TTL for pending tool calls (seconds). */
exports.PENDING_TOOL_CALL_TTL = 300; // 5 minutes
//# sourceMappingURL=session.js.map
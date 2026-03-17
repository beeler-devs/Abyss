import { ConversationTurn, ModelProvider } from "./types.js";
import { logger } from "./logger.js";

/**
 * Summarizes older conversation turns into a compact context paragraph
 * using the same LLM provider, then replaces those turns with the summary.
 *
 * Flow:
 * 1. Called after runConductorLoop completes (no latency impact on current request)
 * 2. If history exceeds SUMMARIZE_AFTER threshold, splits into old + recent
 * 3. Asks the LLM to summarize the old turns into a concise paragraph
 * 4. Replaces old turns with a single "system" turn containing the summary
 * 5. Next LLM call gets the summary prepended to the system prompt
 */

const SUMMARIZE_PROMPT = [
  "Summarize the following conversation history into a concise context paragraph (3-6 sentences).",
  "Focus on: key facts discussed, decisions made, actions taken (tool calls and their outcomes), and any ongoing tasks.",
  "Do NOT include greetings, filler, or meta-commentary.",
  "Write in third person past tense (e.g., 'The user asked about...', 'An email was sent to...').",
  "Include specific details like names, dates, email addresses, event titles, and repository names that were mentioned.",
  "If previous context was provided, incorporate it — do not lose earlier information.",
].join(" ");

export interface SummarizationConfig {
  /** Number of history entries that triggers summarization. Default: 30 */
  summarizeAfter: number;
  /** Number of recent entries to keep in full detail. Default: 10 */
  recentToKeep: number;
}

export const DEFAULT_SUMMARIZATION_CONFIG: SummarizationConfig = {
  summarizeAfter: 30,
  recentToKeep: 10,
};

/**
 * Format conversation turns into a readable text block for the summarizer.
 */
function formatTurnsForSummary(turns: ConversationTurn[], existingSummary?: string): string {
  const parts: string[] = [];

  if (existingSummary) {
    parts.push(`[Previous context summary]\n${existingSummary}\n`);
  }

  for (const turn of turns) {
    if (turn.role === "system") continue;

    if (turn.role === "user") {
      parts.push(`User: ${turn.content as string}`);
    } else if (turn.role === "assistant") {
      if (typeof turn.content === "string") {
        parts.push(`Assistant: ${turn.content}`);
      } else if (Array.isArray(turn.content)) {
        const toolNames = turn.content.map((tc) => tc.name).join(", ");
        parts.push(`Assistant: [Called tools: ${toolNames}]`);
      }
    } else if (turn.role === "tool") {
      const name = turn.tool_name ?? "unknown";
      const content = typeof turn.content === "string" ? turn.content : JSON.stringify(turn.content);
      // Truncate very long tool results for the summarizer
      const truncated = content.length > 500 ? content.slice(0, 500) + "..." : content;
      parts.push(`Tool result (${name}): ${truncated}`);
    }
  }

  return parts.join("\n");
}

/**
 * Check if history needs summarization and perform it if so.
 * Mutates the session history in place.
 *
 * Returns true if summarization was performed.
 */
export async function summarizeIfNeeded(
  history: ConversationTurn[],
  existingSummary: string | undefined,
  provider: ModelProvider,
  config: SummarizationConfig = DEFAULT_SUMMARIZATION_CONFIG,
): Promise<{ summarized: boolean; newSummary?: string; newHistory?: ConversationTurn[] }> {
  if (history.length <= config.summarizeAfter) {
    return { summarized: false };
  }

  let splitIndex = history.length - config.recentToKeep;
  if (splitIndex <= 0) {
    return { summarized: false };
  }

  // Ensure we don't split between an assistant toolUse turn and its toolResult turns.
  // Walk the split point backward until the first kept turn is NOT a tool result,
  // so we never orphan toolResult blocks from their preceding toolUse.
  while (splitIndex > 0 && history[splitIndex].role === "tool") {
    splitIndex--;
  }
  if (splitIndex <= 0) {
    return { summarized: false };
  }

  const oldTurns = history.slice(0, splitIndex);
  const recentTurns = history.slice(splitIndex);

  const formattedHistory = formatTurnsForSummary(oldTurns, existingSummary);

  try {
    const response = await provider.generateResponse([
      {
        role: "user",
        content: `${SUMMARIZE_PROMPT}\n\n---\n${formattedHistory}\n---`,
      },
    ]);

    // Collect the full response text
    let summaryText = "";
    for await (const chunk of response.chunks) {
      summaryText += chunk;
    }
    if (!summaryText.trim()) {
      summaryText = response.fullText;
    }
    summaryText = summaryText.trim();

    if (!summaryText) {
      logger.warn("Context summarization produced empty result, skipping");
      return { summarized: false };
    }

    logger.info(
      `Context summarized: ${oldTurns.length} turns → ${summaryText.length} chars, keeping ${recentTurns.length} recent turns`,
    );

    return {
      summarized: true,
      newSummary: summaryText,
      newHistory: recentTurns,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    logger.warn(`Context summarization failed: ${message}, falling back to truncation`);
    return { summarized: false };
  }
}

export function chunkText(text: string, minChunk = 30, maxChunk = 80): string[] {
  if (!text.trim()) {
    return [];
  }

  const chunks: string[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    const remaining = text.length - cursor;
    const target = Math.min(remaining, randomBetween(minChunk, maxChunk));

    let end = cursor + target;
    if (end < text.length) {
      const breakpoint = text.lastIndexOf(" ", end);
      if (breakpoint > cursor + Math.floor(minChunk / 2)) {
        end = breakpoint;
      }
    }

    chunks.push(text.slice(cursor, end).trimStart());
    cursor = end;
  }

  return chunks.filter((chunk) => chunk.length > 0);
}

export async function* streamFromChunks(chunks: string[], delayMs: number): AsyncIterable<string> {
  for (const chunk of chunks) {
    yield chunk;
    if (delayMs > 0) {
      await sleep(delayMs);
    }
  }
}

export async function* streamSingle(text: string): AsyncIterable<string> {
  if (text) {
    yield text;
  }
}

function randomBetween(min: number, max: number): number {
  const lower = Math.min(min, max);
  const upper = Math.max(min, max);
  return Math.floor(Math.random() * (upper - lower + 1)) + lower;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

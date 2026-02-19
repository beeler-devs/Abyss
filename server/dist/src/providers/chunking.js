export function chunkText(text, minChunk = 30, maxChunk = 80) {
    if (!text.trim()) {
        return [];
    }
    const chunks = [];
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
export async function* streamFromChunks(chunks, delayMs) {
    for (const chunk of chunks) {
        yield chunk;
        if (delayMs > 0) {
            await sleep(delayMs);
        }
    }
}
export async function* streamSingle(text) {
    if (text) {
        yield text;
    }
}
function randomBetween(min, max) {
    const lower = Math.min(min, max);
    const upper = Math.max(min, max);
    return Math.floor(Math.random() * (upper - lower + 1)) + lower;
}
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

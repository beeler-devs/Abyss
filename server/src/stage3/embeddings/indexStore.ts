import { EmbeddingsProvider } from "./provider.js";

export interface IndexedChunk {
  id: string;
  repo: string;
  ref: string;
  path: string;
  startLine: number;
  endLine: number;
  text: string;
  vector: number[];
}

export interface QueryResult {
  path: string;
  startLine: number;
  endLine: number;
  score: number;
  text: string;
}

function cosineSimilarity(a: number[], b: number[]): number {
  const len = Math.min(a.length, b.length);
  let dot = 0;
  let aNorm = 0;
  let bNorm = 0;

  for (let i = 0; i < len; i += 1) {
    dot += a[i] * b[i];
    aNorm += a[i] * a[i];
    bNorm += b[i] * b[i];
  }

  if (aNorm === 0 || bNorm === 0) {
    return 0;
  }

  return dot / (Math.sqrt(aNorm) * Math.sqrt(bNorm));
}

function chunkText(path: string, content: string): Array<{ id: string; path: string; startLine: number; endLine: number; text: string }> {
  const lines = content.split(/\r?\n/);
  const chunks: Array<{ id: string; path: string; startLine: number; endLine: number; text: string }> = [];
  const chunkSize = 80;
  const overlap = 20;

  for (let i = 0; i < lines.length; i += (chunkSize - overlap)) {
    const slice = lines.slice(i, i + chunkSize);
    if (slice.length === 0) {
      continue;
    }

    const startLine = i + 1;
    const endLine = i + slice.length;
    const text = slice.join("\n");
    chunks.push({
      id: `${path}:${startLine}-${endLine}`,
      path,
      startLine,
      endLine,
      text,
    });

    if (i + chunkSize >= lines.length) {
      break;
    }
  }

  return chunks;
}

export class EmbeddingsIndexStore {
  private readonly provider: EmbeddingsProvider;
  private readonly chunks = new Map<string, IndexedChunk[]>();

  constructor(provider: EmbeddingsProvider) {
    this.provider = provider;
  }

  private key(repo: string, ref: string): string {
    return `${repo}@${ref}`;
  }

  async indexFiles(repo: string, ref: string, files: Array<{ path: string; content: string }>): Promise<{ indexedChunks: number }> {
    const k = this.key(repo, ref);
    const existing = this.chunks.get(k) ?? [];
    const retained = existing.filter((chunk) => !files.some((file) => file.path === chunk.path));

    const newChunks: IndexedChunk[] = [];
    for (const file of files) {
      const parsedChunks = chunkText(file.path, file.content);
      for (const parsed of parsedChunks) {
        const vector = await this.provider.embed(parsed.text);
        newChunks.push({
          id: parsed.id,
          repo,
          ref,
          path: parsed.path,
          startLine: parsed.startLine,
          endLine: parsed.endLine,
          text: parsed.text,
          vector,
        });
      }
    }

    this.chunks.set(k, [...retained, ...newChunks]);
    return { indexedChunks: newChunks.length };
  }

  async query(repo: string, ref: string, query: string, topK: number): Promise<QueryResult[]> {
    const k = this.key(repo, ref);
    const indexed = this.chunks.get(k) ?? [];
    if (indexed.length === 0) {
      return [];
    }

    const queryVector = await this.provider.embed(query);

    const scored = indexed
      .map((chunk) => ({
        chunk,
        score: cosineSimilarity(queryVector, chunk.vector),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, Math.max(1, Math.min(topK, 50)));

    return scored.map(({ chunk, score }) => ({
      path: chunk.path,
      startLine: chunk.startLine,
      endLine: chunk.endLine,
      score,
      text: chunk.text,
    }));
  }
}

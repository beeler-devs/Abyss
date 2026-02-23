export interface EmbeddingsProvider {
  readonly name: string;
  embed(text: string): Promise<number[]>;
}

const DIMENSIONS = 128;

function hashToken(token: string): number {
  let hash = 0;
  for (let i = 0; i < token.length; i += 1) {
    hash = (hash * 31 + token.charCodeAt(i)) >>> 0;
  }
  return hash;
}

export class HashEmbeddingsProvider implements EmbeddingsProvider {
  readonly name = "hash-embeddings";

  async embed(text: string): Promise<number[]> {
    const vec = new Array<number>(DIMENSIONS).fill(0);
    const tokens = text.toLowerCase().split(/[^a-z0-9_]+/).filter(Boolean);

    for (const token of tokens) {
      const h = hashToken(token);
      const idx = h % DIMENSIONS;
      const sign = (h & 1) === 0 ? 1 : -1;
      vec[idx] += sign * (1 + (token.length % 5));
    }

    const norm = Math.sqrt(vec.reduce((acc, value) => acc + value * value, 0)) || 1;
    return vec.map((value) => value / norm);
  }
}

export interface SearchClientConfig {
  apiKey: string;
  timeoutMs?: number;
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

export interface SearchResponse {
  query: string;
  results: SearchResult[];
}

export class SearchClient {
  private readonly apiKey: string;
  private readonly timeoutMs: number;

  constructor(config: SearchClientConfig) {
    this.apiKey = config.apiKey?.trim() ?? "";
    this.timeoutMs = config.timeoutMs ?? 10_000;
  }

  isConfigured(): boolean {
    return this.apiKey.length > 0;
  }

  async search(query: string, maxResults?: number): Promise<SearchResponse> {
    const count = Math.min(Math.max(maxResults ?? 5, 1), 10);
    const params = new URLSearchParams({
      q: query,
      count: String(count),
      text_decorations: "false",
      search_lang: "en",
    });

    const url = `https://api.search.brave.com/res/v1/web/search?${params.toString()}`;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        "X-Subscription-Token": this.apiKey,
        "Accept": "application/json",
      },
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`search_http_${response.status}:${text.slice(0, 200)}`);
    }

    const data = await response.json() as Record<string, unknown>;
    const web = data.web as Record<string, unknown> | undefined;
    const rawResults = Array.isArray(web?.results) ? web!.results : [];

    const results: SearchResult[] = rawResults.map((r: Record<string, unknown>) => ({
      title: typeof r.title === "string" ? r.title : "",
      url: typeof r.url === "string" ? r.url : "",
      snippet: typeof r.description === "string" ? r.description.slice(0, 300) : "",
    }));

    return { query, results };
  }
}

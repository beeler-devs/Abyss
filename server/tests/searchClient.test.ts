import test from "node:test";
import assert from "node:assert/strict";

import { SearchClient } from "../src/integrations/searchClient.js";

function mockFetch(
  handler: (input: string, init?: RequestInit) => Promise<Response> | Response,
): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    return handler(url, init);
  }) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
}

test("isConfigured returns false when apiKey is empty", () => {
  const client = new SearchClient({ apiKey: "" });
  assert.equal(client.isConfigured(), false);

  const clientWhitespace = new SearchClient({ apiKey: "   " });
  assert.equal(clientWhitespace.isConfigured(), false);
});

test("isConfigured returns true when apiKey is set", () => {
  const client = new SearchClient({ apiKey: "BSA_test_key" });
  assert.equal(client.isConfigured(), true);
});

test("search sends correct URL, query params, and X-Subscription-Token header", async () => {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const restoreFetch = mockFetch(async (url, init) => {
    calls.push({ url, init });
    return new Response(JSON.stringify({
      web: {
        results: [
          { title: "Example", url: "https://example.com", description: "An example page" },
        ],
      },
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  });

  try {
    const client = new SearchClient({ apiKey: "BSA_test_key" });
    const response = await client.search("test query", 3);

    assert.equal(calls.length, 1);
    const parsedUrl = new URL(calls[0]!.url);
    assert.equal(parsedUrl.origin + parsedUrl.pathname, "https://api.search.brave.com/res/v1/web/search");
    assert.equal(parsedUrl.searchParams.get("q"), "test query");
    assert.equal(parsedUrl.searchParams.get("count"), "3");
    assert.equal(parsedUrl.searchParams.get("text_decorations"), "false");
    assert.equal(parsedUrl.searchParams.get("search_lang"), "en");

    const headers = new Headers(calls[0]?.init?.headers);
    assert.equal(headers.get("X-Subscription-Token"), "BSA_test_key");
    assert.equal(headers.get("Accept"), "application/json");

    assert.equal(response.query, "test query");
    assert.equal(response.results.length, 1);
    assert.equal(response.results[0]?.title, "Example");
    assert.equal(response.results[0]?.url, "https://example.com");
    assert.equal(response.results[0]?.snippet, "An example page");
  } finally {
    restoreFetch();
  }
});

test("non-2xx response throws with search_http_<status> prefix", async () => {
  const restoreFetch = mockFetch(async () => new Response("Rate limit exceeded", { status: 429 }));

  try {
    const client = new SearchClient({ apiKey: "BSA_test_key" });
    await assert.rejects(
      client.search("test"),
      /search_http_429:Rate limit exceeded/,
    );
  } finally {
    restoreFetch();
  }
});

test("web.results normalized to SearchResponse, snippets truncated to 300 chars", async () => {
  const longDescription = "x".repeat(500);
  const restoreFetch = mockFetch(async () => new Response(JSON.stringify({
    web: {
      results: [
        { title: "Result 1", url: "https://a.com", description: longDescription },
        { title: "Result 2", url: "https://b.com", description: "Short" },
        { title: 123, url: null, description: false },
      ],
    },
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  }));

  try {
    const client = new SearchClient({ apiKey: "BSA_test_key" });
    const response = await client.search("query");

    assert.equal(response.results.length, 3);
    assert.equal(response.results[0]?.snippet.length, 300);
    assert.equal(response.results[1]?.snippet, "Short");
    // Non-string fields default to empty string
    assert.equal(response.results[2]?.title, "");
    assert.equal(response.results[2]?.url, "");
    assert.equal(response.results[2]?.snippet, "");
  } finally {
    restoreFetch();
  }
});

test("missing web.results returns empty results array", async () => {
  const restoreFetch = mockFetch(async () => new Response(JSON.stringify({
    query: { original: "test" },
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  }));

  try {
    const client = new SearchClient({ apiKey: "BSA_test_key" });
    const response = await client.search("test");

    assert.equal(response.query, "test");
    assert.deepEqual(response.results, []);
  } finally {
    restoreFetch();
  }
});

test("maxResults is clamped to 10", async () => {
  const calls: Array<{ url: string }> = [];
  const restoreFetch = mockFetch(async (url) => {
    calls.push({ url });
    return new Response(JSON.stringify({ web: { results: [] } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  });

  try {
    const client = new SearchClient({ apiKey: "BSA_test_key" });
    await client.search("test", 50);

    const parsedUrl = new URL(calls[0]!.url);
    assert.equal(parsedUrl.searchParams.get("count"), "10");
  } finally {
    restoreFetch();
  }
});

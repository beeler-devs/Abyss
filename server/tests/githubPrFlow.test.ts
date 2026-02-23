import test from "node:test";
import assert from "node:assert/strict";

import { GitHubClient } from "../src/stage3/github/githubClient.js";

type FetchCall = { url: string; method: string; body?: unknown };

function withMockFetch(
  handlers: Array<(call: FetchCall) => Response>,
  fn: () => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  let index = 0;

  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const handler = handlers[index];
    if (!handler) {
      return new Response(JSON.stringify({ message: "unexpected_call" }), { status: 500 });
    }

    index += 1;
    const call: FetchCall = {
      url: typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url,
      method: init?.method ?? "GET",
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
    };
    return handler(call);
  }) as typeof fetch;

  return fn().finally(() => {
    globalThis.fetch = originalFetch;
  });
}

test("github.pr.openOrUpdate creates PR when no open match exists", async () => {
  await withMockFetch([
    (call) => {
      assert.equal(call.method, "GET");
      assert.match(call.url, /\/pulls\?/);
      return new Response(JSON.stringify([]), { status: 200 });
    },
    (call) => {
      assert.equal(call.method, "POST");
      assert.match(call.url, /\/pulls$/);
      const body = call.body as Record<string, unknown>;
      assert.equal(body.title, "Fix failing test");
      return new Response(JSON.stringify({ number: 42, html_url: "https://github.com/acme/repo/pull/42" }), { status: 201 });
    },
  ], async () => {
    const client = new GitHubClient("token-test", "https://api.github.test");
    const result = await client.openOrUpdatePr({
      ref: { owner: "acme", repo: "repo" },
      base: "main",
      head: "abyss/stage3",
      title: "Fix failing test",
      body: "Automated body",
      draft: true,
    });

    assert.equal(result.number, 42);
    assert.equal(result.url, "https://github.com/acme/repo/pull/42");
  });
});

test("github.pr.openOrUpdate updates existing open PR", async () => {
  await withMockFetch([
    (call) => {
      assert.equal(call.method, "GET");
      return new Response(JSON.stringify([{ number: 7, html_url: "https://github.com/acme/repo/pull/7" }]), { status: 200 });
    },
    (call) => {
      assert.equal(call.method, "PATCH");
      assert.match(call.url, /\/pulls\/7$/);
      const body = call.body as Record<string, unknown>;
      assert.equal(body.title, "Updated title");
      return new Response(JSON.stringify({ number: 7, html_url: "https://github.com/acme/repo/pull/7" }), { status: 200 });
    },
  ], async () => {
    const client = new GitHubClient("token-test", "https://api.github.test");
    const result = await client.openOrUpdatePr({
      ref: { owner: "acme", repo: "repo" },
      base: "main",
      head: "abyss/stage3",
      title: "Updated title",
      body: "Body",
    });

    assert.equal(result.number, 7);
    assert.equal(result.url, "https://github.com/acme/repo/pull/7");
  });
});

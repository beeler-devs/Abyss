import test from "node:test";
import assert from "node:assert/strict";

import { SessionState } from "../src/core/types.js";
import { GitHubClient } from "../src/integrations/githubClient.js";

function makeSession(githubToken?: string): SessionState {
  return {
    sessionId: "session-github-test",
    githubToken,
    history: [],
    pendingToolCalls: new Map(),
    toolResultResolvers: new Map(),
    pendingGmailSends: new Map(),
    pendingCalendarMutations: new Map(),
    recentTranscriptTrace: [],
    transcriptCount: 0,
  };
}

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

test("github client requires authentication", async () => {
  const client = new GitHubClient();
  assert.equal(client.isAuthenticated(makeSession()), false);
  assert.equal(client.isAuthenticated(makeSession("gho_test")), true);

  await assert.rejects(
    client.listRepos(makeSession()),
    /github_not_authenticated/,
  );
});

test("github client sends auth headers and normalizes repositories", async () => {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const restoreFetch = mockFetch(async (url, init) => {
    calls.push({ url, init });
    return new Response(JSON.stringify([{
      full_name: "acme/voicebot",
      name: "voicebot",
      default_branch: "main",
      private: true,
      updated_at: "2026-03-15T12:00:00Z",
    }]), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  });

  try {
    const client = new GitHubClient();
    const repositories = await client.listRepos(makeSession("gho_test"), { limit: 5 });

    assert.equal(calls.length, 1);
    assert.equal(calls[0]?.url, "https://api.github.com/user/repos?sort=updated&per_page=5");
    const headers = new Headers(calls[0]?.init?.headers);
    assert.equal(headers.get("authorization"), "Bearer gho_test");
    assert.equal(headers.get("accept"), "application/vnd.github+json");
    assert.equal(repositories[0]?.fullName, "acme/voicebot");
    assert.equal(repositories[0]?.defaultBranch, "main");
    assert.equal(repositories[0]?.isPrivate, true);
  } finally {
    restoreFetch();
  }
});

test("github client surfaces non-2xx responses with github_http prefix", async () => {
  const restoreFetch = mockFetch(async () => new Response("Not Found", { status: 404 }));

  try {
    const client = new GitHubClient();
    await assert.rejects(
      client.listRepos(makeSession("gho_test")),
      /github_http_404:Not Found/,
    );
  } finally {
    restoreFetch();
  }
});

test("github client combines reviews and comments into a summary", async () => {
  const restoreFetch = mockFetch(async (url) => {
    if (url.endsWith("/reviews?per_page=100")) {
      return new Response(JSON.stringify([
        {
          state: "COMMENTED",
          body: "Looks fine overall.",
          submitted_at: "2026-03-15T10:00:00Z",
          user: { login: "alice" },
        },
        {
          state: "CHANGES_REQUESTED",
          body: "Please fix the failing test.",
          submitted_at: "2026-03-15T11:00:00Z",
          user: { login: "bob" },
        },
      ]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify([
      {
        body: "x".repeat(550),
        path: "server/src/app.ts",
        line: 42,
        created_at: "2026-03-15T11:05:00Z",
        user: { login: "bob" },
      },
    ]), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  });

  try {
    const client = new GitHubClient();
    const summary = await client.getReviews(makeSession("gho_test"), {
      repo: "acme/voicebot",
      prNumber: 42,
    });

    assert.equal(summary.repo, "acme/voicebot");
    assert.equal(summary.prNumber, 42);
    assert.equal(summary.overallState, "changes_requested");
    assert.equal(summary.reviews.length, 2);
    assert.equal(summary.comments[0]?.reviewer, "bob");
    assert.equal(summary.comments[0]?.path, "server/src/app.ts");
    assert.equal(summary.comments[0]?.line, 42);
    assert.equal(summary.comments[0]?.body.length, 500);
    assert.equal(summary.comments[0]?.body.endsWith("…"), true);
  } finally {
    restoreFetch();
  }
});

test("github client summarizes latest workflow runs", async () => {
  const restoreFetch = mockFetch(async () => new Response(JSON.stringify({
    workflow_runs: [
      {
        name: "CI",
        status: "in_progress",
        conclusion: null,
        html_url: "https://github.com/acme/voicebot/actions/runs/2",
        created_at: "2026-03-15T11:00:00Z",
      },
      {
        name: "CI",
        status: "completed",
        conclusion: "failure",
        html_url: "https://github.com/acme/voicebot/actions/runs/1",
        created_at: "2026-03-15T10:00:00Z",
      },
      {
        name: "Lint",
        status: "completed",
        conclusion: "success",
        html_url: "https://github.com/acme/voicebot/actions/runs/3",
        created_at: "2026-03-15T11:05:00Z",
      },
    ],
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  }));

  try {
    const client = new GitHubClient();
    const status = await client.getActionsStatus(makeSession("gho_test"), {
      repo: "acme/voicebot",
      branch: "feature/github-tools",
    });

    assert.equal(status.repo, "acme/voicebot");
    assert.equal(status.branch, "feature/github-tools");
    assert.equal(status.overallStatus, "pending");
    assert.equal(status.runs.length, 2);
    assert.deepEqual(status.runs.map((run) => run.name), ["CI", "Lint"]);
    assert.equal(status.runs[0]?.status, "in_progress");
  } finally {
    restoreFetch();
  }
});

test("github client filters pull requests out of issue results", async () => {
  const restoreFetch = mockFetch(async () => new Response(JSON.stringify([
    {
      number: 10,
      title: "Bug in auth flow",
      state: "open",
      html_url: "https://github.com/acme/voicebot/issues/10",
      user: { login: "alice" },
      assignees: [{ login: "bob" }],
      labels: [{ name: "bug" }],
      created_at: "2026-03-15T09:00:00Z",
      body: "Issue body",
    },
    {
      number: 11,
      title: "Actually a PR",
      state: "open",
      html_url: "https://github.com/acme/voicebot/pull/11",
      pull_request: { url: "https://api.github.com/repos/acme/voicebot/pulls/11" },
      created_at: "2026-03-15T09:30:00Z",
    },
  ]), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  }));

  try {
    const client = new GitHubClient();
    const issues = await client.listIssues(makeSession("gho_test"), {
      repo: "acme/voicebot",
    });

    assert.equal(issues.length, 1);
    assert.equal(issues[0]?.number, 10);
    assert.equal(issues[0]?.repo, "acme/voicebot");
    assert.deepEqual(issues[0]?.labels, ["bug"]);
  } finally {
    restoreFetch();
  }
});

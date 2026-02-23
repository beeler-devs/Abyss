import test from "node:test";
import assert from "node:assert/strict";

import { ContextEngine } from "../src/stage3/context/contextEngine.js";
import { EmbeddingsIndexStore } from "../src/stage3/embeddings/indexStore.js";
import { HashEmbeddingsProvider } from "../src/stage3/embeddings/provider.js";
import { GitHubClient } from "../src/stage3/github/githubClient.js";

class MockGitHub {
  async listTree(): Promise<Array<{ path: string; type: string; sha: string }>> {
    return [
      { path: "src/sum.ts", type: "blob", sha: "sha-sum" },
      { path: "src/sum.test.ts", type: "blob", sha: "sha-test" },
      { path: "package.json", type: "blob", sha: "sha-pkg" },
    ];
  }

  async getFile(_repo: unknown, _ref: string, path: string): Promise<{ content: string; sha: string }> {
    const files: Record<string, string> = {
      "src/sum.ts": "export const sum=(a:number,b:number)=>a-b;",
      "src/sum.test.ts": "it('sum',()=>expect(sum(2,3)).toBe(5));",
      "package.json": "{\"scripts\":{\"test\":\"vitest\"}}",
    };
    return {
      content: files[path] ?? "",
      sha: `sha-${path}`,
    };
  }
}

test("context.buildBundle prioritizes stack paths and respects budget", async () => {
  const embeddings = new EmbeddingsIndexStore(new HashEmbeddingsProvider());
  await embeddings.indexFiles("acme/repo", "main", [
    { path: "src/sum.ts", content: "export const sum=(a:number,b:number)=>a-b;" },
    { path: "src/sum.test.ts", content: "expect(sum(2,3)).toBe(5)" },
  ]);

  const engine = new ContextEngine(embeddings);
  const github = new MockGitHub() as unknown as GitHubClient;

  const bundle = await engine.buildBundle({
    github,
    repo: "acme/repo",
    ref: "main",
    goal: "Fix failing sum test",
    failureSignals: {
      signature: "test:abc",
      stackPaths: ["src/sum.ts"],
      suggestedQueries: ["sum"],
      logsExcerpt: "AssertionError",
    },
    constraints: {
      allowedPaths: ["src/"],
      noReformat: true,
      maxDiffLines: 100,
      mustFixSignature: "test:abc",
    },
    budget: {
      maxChars: 120,
      topFullFiles: 2,
      topSnippets: 2,
    },
  });

  assert.equal(bundle.fullFiles.length > 0, true);
  assert.equal(bundle.fullFiles[0]?.path, "src/sum.ts");
  const totalChars = bundle.fullFiles.reduce((acc, file) => acc + file.content.length, 0)
    + bundle.snippets.reduce((acc, snippet) => acc + snippet.text.length, 0);
  assert.equal(totalChars <= 120, true);
});

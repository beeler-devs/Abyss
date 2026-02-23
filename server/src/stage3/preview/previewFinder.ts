import { GitHubClient } from "../github/githubClient.js";
import { parseRepoRef } from "../github/repo.js";

function extractFirstUrl(text: string): string | null {
  const match = text.match(/https?:\/\/[^\s)\]]+/i);
  return match?.[0] ?? null;
}

function isPreviewHost(url: string): boolean {
  return /(vercel\.app|netlify\.app|pages\.dev|onrender\.com|herokuapp\.com|preview)/i.test(url);
}

export async function findPreviewUrl(args: {
  github: GitHubClient;
  repo: string;
  prNumber: number;
  checks?: Array<{ url: string }>;
}): Promise<{ url: string; source: string }> {
  const { github, repo, prNumber, checks = [] } = args;
  const parsedRepo = parseRepoRef(repo);

  for (const check of checks) {
    if (check.url && isPreviewHost(check.url)) {
      return { url: check.url, source: "check_run_url" };
    }
  }

  const comments = await github.listIssueComments(parsedRepo, prNumber);
  for (const comment of comments) {
    const url = extractFirstUrl(comment.body);
    if (url && isPreviewHost(url)) {
      return { url, source: "pr_comment" };
    }
  }

  for (const comment of comments) {
    const fallback = extractFirstUrl(comment.body);
    if (fallback) {
      return { url: fallback, source: "pr_comment_any" };
    }
  }

  throw new Error("preview_url_not_found");
}

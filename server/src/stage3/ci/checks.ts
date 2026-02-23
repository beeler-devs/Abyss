import { GitHubClient, GitHubCheckSummary } from "../github/githubClient.js";
import { parseRepoRef } from "../github/repo.js";

export async function listChecksForPr(github: GitHubClient, repo: string, prNumber: number): Promise<GitHubCheckSummary[]> {
  const parsedRepo = parseRepoRef(repo);
  const pr = await github.getPr(parsedRepo, prNumber);
  return github.listChecksBySha(parsedRepo, pr.headSha);
}

export function summarizeChecks(checks: GitHubCheckSummary[]): { pass: boolean; summary: string; failingCheck?: GitHubCheckSummary } {
  if (checks.length === 0) {
    return {
      pass: false,
      summary: "No checks found for this PR yet.",
    };
  }

  const failing = checks.find((check) => check.status === "completed" && check.conclusion && check.conclusion !== "success" && check.conclusion !== "neutral")
    ?? checks.find((check) => check.status !== "completed");

  if (!failing) {
    return {
      pass: true,
      summary: `All ${checks.length} checks are green.`,
    };
  }

  const conclusion = failing.conclusion ?? failing.status;
  return {
    pass: false,
    summary: `Failing check: ${failing.name} (${conclusion}).`,
    failingCheck: failing,
  };
}

export async function waitForChecksTerminal(
  github: GitHubClient,
  repo: string,
  prNumber: number,
  timeoutMs: number,
): Promise<GitHubCheckSummary[]> {
  const started = Date.now();
  let lastChecks: GitHubCheckSummary[] = [];

  while (Date.now() - started < timeoutMs) {
    lastChecks = await listChecksForPr(github, repo, prNumber);
    if (lastChecks.length > 0 && lastChecks.every((check) => check.status === "completed")) {
      return lastChecks;
    }
    await new Promise((resolve) => setTimeout(resolve, 8_000));
  }

  return lastChecks;
}

import { GitHubClient } from "../github/githubClient.js";
import { parseRepoRef } from "../github/repo.js";
import { applyPatchToText, parseUnifiedDiff } from "./unifiedDiff.js";

export async function applyPatchToBranch(args: {
  github: GitHubClient;
  repo: string;
  branch: string;
  unifiedDiff: string;
  commitMessage: string;
}): Promise<{ commitSha: string; changedFiles: string[] }> {
  const { github, repo, branch, unifiedDiff, commitMessage } = args;
  const parsedRepo = parseRepoRef(repo);
  const patches = parseUnifiedDiff(unifiedDiff);

  const changedFiles: string[] = [];
  let lastCommitSha = "";

  for (const patch of patches) {
    const path = patch.newPath || patch.oldPath;
    if (!path || path === "/dev/null") {
      continue;
    }

    const existing = await github.getFile(parsedRepo, branch, path);
    const nextContent = applyPatchToText(existing.content, patch);
    const updated = await github.putFile(parsedRepo, branch, path, nextContent, commitMessage, existing.sha);
    changedFiles.push(path);
    lastCommitSha = updated.commitSha;
  }

  return {
    commitSha: lastCommitSha,
    changedFiles,
  };
}

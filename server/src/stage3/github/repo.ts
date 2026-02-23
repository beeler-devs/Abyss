export interface RepoRef {
  owner: string;
  repo: string;
}

export function parseRepoRef(input: string): RepoRef {
  const cleaned = input.trim().replace(/^https:\/\/github.com\//, "").replace(/\.git$/, "");
  const [owner, repo] = cleaned.split("/");
  if (!owner || !repo) {
    throw new Error(`invalid_repo:${input}`);
  }
  return { owner, repo };
}

export function formatRepo(ref: RepoRef): string {
  return `${ref.owner}/${ref.repo}`;
}

export function sanitizeBranchName(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9/_-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^[-/]+|[-/]+$/g, "")
    .slice(0, 120);
}

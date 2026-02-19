const GITHUB_API = "https://api.github.com";

function githubHeaders(token: string): Record<string, string> {
  return {
    "Authorization": `Bearer ${token}`,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "Abyss-Voice-Assistant",
  };
}

export interface GitHubOrg {
  login: string;
  description: string | null;
}

export interface GitHubRepo {
  full_name: string;
  description: string | null;
  private: boolean;
  language: string | null;
  stargazers_count: number;
  updated_at: string | null;
}

/**
 * List organizations the authenticated user belongs to.
 * Returns a compact JSON string suitable for inclusion in an LLM tool result.
 */
export async function listOrganizations(token: string): Promise<string> {
  const response = await fetch(`${GITHUB_API}/user/orgs?per_page=100`, {
    headers: githubHeaders(token),
    signal: AbortSignal.timeout(10_000),
  });

  if (!response.ok) {
    throw new Error(`GitHub API error ${response.status}: ${await response.text()}`);
  }

  const orgs = (await response.json()) as GitHubOrg[];
  const compact = orgs.map((o) => ({
    login: o.login,
    description: o.description ?? undefined,
  }));

  return JSON.stringify({ organizations: compact, count: compact.length });
}

/**
 * List repositories for the authenticated user or a specific organization.
 * When `org` is provided, returns repos for that org instead of the user's repos.
 */
export async function listRepositories(token: string, org?: string): Promise<string> {
  const url = org
    ? `${GITHUB_API}/orgs/${encodeURIComponent(org)}/repos?per_page=100&sort=updated&type=all`
    : `${GITHUB_API}/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member`;

  const response = await fetch(url, {
    headers: githubHeaders(token),
    signal: AbortSignal.timeout(10_000),
  });

  if (!response.ok) {
    throw new Error(`GitHub API error ${response.status}: ${await response.text()}`);
  }

  const repos = (await response.json()) as GitHubRepo[];
  const compact = repos.map((r) => ({
    full_name: r.full_name,
    description: r.description ?? undefined,
    private: r.private,
    language: r.language ?? undefined,
    stars: r.stargazers_count,
    updated_at: r.updated_at ?? undefined,
  }));

  return JSON.stringify({ repositories: compact, count: compact.length, org: org ?? null });
}

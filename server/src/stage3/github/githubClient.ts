import { RepoRef, formatRepo } from "./repo.js";

export interface GitHubRepoSummary {
  owner: string;
  name: string;
  fullName: string;
  defaultBranch: string;
  private: boolean;
  htmlUrl: string;
}

export interface GitHubCheckSummary {
  id: number;
  name: string;
  status: string;
  conclusion: string | null;
  url: string;
}

export interface GitHubTreeEntry {
  path: string;
  type: string;
  sha: string;
  size?: number;
}

export interface GitHubPullRequestInfo {
  number: number;
  url: string;
  headRef: string;
  baseRef: string;
}

interface RequestOptions {
  method?: string;
  body?: unknown;
  accept?: string;
}

const DEFAULT_API_BASE = "https://api.github.com";

function buildHeaders(token: string, accept?: string): Record<string, string> {
  const headers: Record<string, string> = {
    "Authorization": `Bearer ${token}`,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "Abyss-Stage3-ToolServer",
    "Accept": accept ?? "application/vnd.github+json",
  };
  return headers;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

export class GitHubClient {
  private readonly token: string;
  private readonly apiBase: string;

  constructor(token: string, apiBase: string = DEFAULT_API_BASE) {
    if (!token.trim()) {
      throw new Error("missing_github_token");
    }
    this.token = token;
    this.apiBase = apiBase.replace(/\/$/, "");
  }

  private async request(path: string, options: RequestOptions = {}): Promise<unknown> {
    const method = options.method ?? "GET";
    const response = await fetch(`${this.apiBase}${path}`, {
      method,
      headers: buildHeaders(this.token, options.accept),
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(20_000),
    });

    if (response.status === 204) {
      return {};
    }

    const text = await response.text();
    const json = text ? (() => {
      try {
        return JSON.parse(text) as unknown;
      } catch {
        return text;
      }
    })() : {};

    if (!response.ok) {
      const message = typeof json === "string"
        ? json
        : isObject(json) && typeof json.message === "string"
          ? json.message
          : `github_http_${response.status}`;
      throw new Error(`github_http_${response.status}:${message}`);
    }

    return json;
  }

  async listRepos(limit = 50): Promise<GitHubRepoSummary[]> {
    const data = await this.request(`/user/repos?per_page=${Math.max(1, Math.min(limit, 100))}&sort=updated`);
    if (!Array.isArray(data)) {
      return [];
    }

    return data
      .filter(isObject)
      .map((repo) => {
        const owner = isObject(repo.owner) ? asString(repo.owner.login) : undefined;
        const name = asString(repo.name);
        return {
          owner: owner ?? "",
          name: name ?? "",
          fullName: asString(repo.full_name) ?? "",
          defaultBranch: asString(repo.default_branch) ?? "main",
          private: Boolean(repo.private),
          htmlUrl: asString(repo.html_url) ?? "",
        } satisfies GitHubRepoSummary;
      })
      .filter((repo) => Boolean(repo.owner && repo.name));
  }

  async getRepo(ref: RepoRef): Promise<{ defaultBranch: string; htmlUrl: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}`);
    if (!isObject(data)) {
      throw new Error("github_invalid_repo_response");
    }
    return {
      defaultBranch: asString(data.default_branch) ?? "main",
      htmlUrl: asString(data.html_url) ?? `https://github.com/${formatRepo(ref)}`,
    };
  }

  async getBranchSha(ref: RepoRef, branch: string): Promise<string> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/branches/${encodeURIComponent(branch)}`);
    if (!isObject(data) || !isObject(data.commit) || !asString(data.commit.sha)) {
      throw new Error("github_missing_branch_sha");
    }
    return asString(data.commit.sha) ?? "";
  }

  async getFile(ref: RepoRef, branchOrSha: string, path: string): Promise<{ content: string; sha: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/contents/${encodeURIComponent(path)}?ref=${encodeURIComponent(branchOrSha)}`);
    if (!isObject(data)) {
      throw new Error("github_invalid_file_response");
    }
    const encoded = asString(data.content)?.replace(/\n/g, "") ?? "";
    const sha = asString(data.sha);
    if (!sha) {
      throw new Error(`github_missing_file_sha:${path}`);
    }
    if (!encoded) {
      return { content: "", sha };
    }
    const content = Buffer.from(encoded, "base64").toString("utf8");
    return { content, sha };
  }

  async putFile(
    ref: RepoRef,
    branch: string,
    path: string,
    content: string,
    message: string,
    sha?: string,
  ): Promise<{ commitSha: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/contents/${encodeURIComponent(path)}`, {
      method: "PUT",
      body: {
        message,
        branch,
        content: Buffer.from(content, "utf8").toString("base64"),
        sha,
      },
    });

    if (!isObject(data) || !isObject(data.commit) || !asString(data.commit.sha)) {
      throw new Error("github_invalid_put_file_response");
    }
    return { commitSha: asString(data.commit.sha) ?? "" };
  }

  async listTree(ref: RepoRef, branchOrSha: string): Promise<GitHubTreeEntry[]> {
    const sha = branchOrSha.length === 40 && /^[a-f0-9]{40}$/.test(branchOrSha)
      ? branchOrSha
      : await this.getBranchSha(ref, branchOrSha);

    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/git/trees/${sha}?recursive=1`);
    if (!isObject(data) || !Array.isArray(data.tree)) {
      return [];
    }

    return data.tree
      .filter(isObject)
      .map((entry) => ({
        path: asString(entry.path) ?? "",
        type: asString(entry.type) ?? "",
        sha: asString(entry.sha) ?? "",
        size: asNumber(entry.size),
      }))
      .filter((entry) => Boolean(entry.path && entry.type && entry.sha));
  }

  async searchCode(ref: RepoRef, query: string): Promise<Array<{ path: string; url: string }>> {
    const q = `${query} repo:${formatRepo(ref)}`;
    const data = await this.request(`/search/code?q=${encodeURIComponent(q)}&per_page=20`);
    if (!isObject(data) || !Array.isArray(data.items)) {
      return [];
    }

    return data.items
      .filter(isObject)
      .map((item) => ({
        path: asString(item.path) ?? "",
        url: asString(item.html_url) ?? "",
      }))
      .filter((item) => Boolean(item.path));
  }

  async createBranch(ref: RepoRef, baseRef: string, newBranch: string): Promise<{ ref: string }> {
    const sha = await this.getBranchSha(ref, baseRef);
    await this.request(`/repos/${ref.owner}/${ref.repo}/git/refs`, {
      method: "POST",
      body: {
        ref: `refs/heads/${newBranch}`,
        sha,
      },
    });
    return { ref: `refs/heads/${newBranch}` };
  }

  async openOrUpdatePr(args: {
    ref: RepoRef;
    base: string;
    head: string;
    title: string;
    body: string;
    draft?: boolean;
  }): Promise<GitHubPullRequestInfo> {
    const { ref, base, head, title, body, draft } = args;
    const existing = await this.request(
      `/repos/${ref.owner}/${ref.repo}/pulls?state=open&head=${encodeURIComponent(`${ref.owner}:${head}`)}&base=${encodeURIComponent(base)}`,
    );

    if (Array.isArray(existing) && existing.length > 0 && isObject(existing[0])) {
      const pr = existing[0];
      const number = asNumber(pr.number);
      if (!number) {
        throw new Error("github_invalid_pr_number");
      }
      const updated = await this.request(`/repos/${ref.owner}/${ref.repo}/pulls/${number}`, {
        method: "PATCH",
        body: { title, body },
      });
      if (!isObject(updated)) {
        throw new Error("github_invalid_pr_update_response");
      }
      return {
        number,
        url: asString(updated.html_url) ?? asString(pr.html_url) ?? "",
        headRef: head,
        baseRef: base,
      };
    }

    const created = await this.request(`/repos/${ref.owner}/${ref.repo}/pulls`, {
      method: "POST",
      body: {
        title,
        head,
        base,
        body,
        draft: Boolean(draft),
      },
    });
    if (!isObject(created) || !asNumber(created.number)) {
      throw new Error("github_invalid_pr_create_response");
    }

    return {
      number: asNumber(created.number) ?? 0,
      url: asString(created.html_url) ?? "",
      headRef: head,
      baseRef: base,
    };
  }

  async listPrFiles(ref: RepoRef, prNumber: number): Promise<Array<{ path: string; patch: string }>> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/pulls/${prNumber}/files?per_page=100`);
    if (!Array.isArray(data)) {
      return [];
    }
    return data
      .filter(isObject)
      .map((file) => ({
        path: asString(file.filename) ?? "",
        patch: asString(file.patch) ?? "",
      }))
      .filter((file) => Boolean(file.path));
  }

  async commentOnPr(ref: RepoRef, prNumber: number, body: string): Promise<{ commentId: number }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/issues/${prNumber}/comments`, {
      method: "POST",
      body: { body },
    });
    if (!isObject(data) || !asNumber(data.id)) {
      throw new Error("github_invalid_comment_response");
    }
    return { commentId: asNumber(data.id) ?? 0 };
  }

  async mergePr(ref: RepoRef, prNumber: number, method: string): Promise<{ merged: boolean; message: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/pulls/${prNumber}/merge`, {
      method: "PUT",
      body: { merge_method: method },
    });
    if (!isObject(data)) {
      throw new Error("github_invalid_merge_response");
    }

    return {
      merged: Boolean(data.merged),
      message: asString(data.message) ?? "",
    };
  }

  async getPr(ref: RepoRef, prNumber: number): Promise<{ headSha: string; headRef: string; baseRef: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/pulls/${prNumber}`);
    if (!isObject(data) || !isObject(data.head) || !isObject(data.base)) {
      throw new Error("github_invalid_pr_response");
    }

    return {
      headSha: asString(data.head.sha) ?? "",
      headRef: asString(data.head.ref) ?? "",
      baseRef: asString(data.base.ref) ?? "",
    };
  }

  async listChecksBySha(ref: RepoRef, sha: string): Promise<GitHubCheckSummary[]> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/commits/${sha}/check-runs`);
    if (!isObject(data) || !Array.isArray(data.check_runs)) {
      return [];
    }
    return data.check_runs
      .filter(isObject)
      .map((check) => ({
        id: asNumber(check.id) ?? 0,
        name: asString(check.name) ?? "",
        status: asString(check.status) ?? "queued",
        conclusion: asString(check.conclusion) ?? null,
        url: asString(check.html_url) ?? asString(check.details_url) ?? "",
      }))
      .filter((check) => Boolean(check.id && check.name));
  }

  async getCheckRun(ref: RepoRef, checkRunId: number): Promise<{
    id: number;
    name: string;
    status: string;
    conclusion: string | null;
    detailsUrl: string;
    outputTitle: string;
    outputSummary: string;
    outputText: string;
  }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/check-runs/${checkRunId}`);
    if (!isObject(data)) {
      throw new Error("github_invalid_check_run");
    }
    const output = isObject(data.output) ? data.output : {};
    return {
      id: asNumber(data.id) ?? checkRunId,
      name: asString(data.name) ?? "",
      status: asString(data.status) ?? "queued",
      conclusion: asString(data.conclusion) ?? null,
      detailsUrl: asString(data.details_url) ?? asString(data.html_url) ?? "",
      outputTitle: asString(output.title) ?? "",
      outputSummary: asString(output.summary) ?? "",
      outputText: asString(output.text) ?? "",
    };
  }

  async rerunCheck(ref: RepoRef, checkRunId: number): Promise<void> {
    await this.request(`/repos/${ref.owner}/${ref.repo}/check-runs/${checkRunId}/rerequest`, {
      method: "POST",
      body: {},
    });
  }

  async workflowDispatch(ref: RepoRef, workflow: string, branch: string, inputs: Record<string, string>): Promise<void> {
    await this.request(`/repos/${ref.owner}/${ref.repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`, {
      method: "POST",
      body: {
        ref: branch,
        inputs,
      },
    });
  }

  async workflowStatus(ref: RepoRef, runId: number): Promise<{ state: string; conclusion: string | null; url: string }> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/actions/runs/${runId}`);
    if (!isObject(data)) {
      throw new Error("github_invalid_workflow_run");
    }

    return {
      state: asString(data.status) ?? "queued",
      conclusion: asString(data.conclusion) ?? null,
      url: asString(data.html_url) ?? "",
    };
  }

  async listIssueComments(ref: RepoRef, issueNumber: number): Promise<Array<{ body: string }>> {
    const data = await this.request(`/repos/${ref.owner}/${ref.repo}/issues/${issueNumber}/comments?per_page=100`);
    if (!Array.isArray(data)) {
      return [];
    }

    return data
      .filter(isObject)
      .map((item) => ({ body: asString(item.body) ?? "" }))
      .filter((item) => Boolean(item.body));
  }
}

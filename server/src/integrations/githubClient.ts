import { logger } from "../core/logger.js";
import { SessionState } from "../core/types.js";

export interface GitHubClientConfig {
  timeoutMs?: number;
}

export interface GitHubPR {
  number: number;
  title: string;
  state: "open" | "closed" | "merged";
  url: string;
  repo: string;
  branch: string;
  baseBranch: string;
  author: string;
  createdAt: string;
  updatedAt: string;
  isDraft: boolean;
  reviewState?: "approved" | "changes_requested" | "review_required" | "pending";
}

export interface GitHubPRDetail extends GitHubPR {
  body: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  mergeable: boolean | null;
  reviewers: string[];
}

export interface GitHubReviewSummary {
  prNumber: number;
  repo: string;
  overallState: "approved" | "changes_requested" | "pending" | "commented";
  reviews: Array<{
    reviewer: string;
    state: "approved" | "changes_requested" | "commented" | "dismissed";
    body: string;
    submittedAt: string;
  }>;
  comments: Array<{
    reviewer: string;
    body: string;
    path?: string;
    line?: number;
    createdAt: string;
  }>;
}

export interface GitHubActionsStatus {
  repo: string;
  branch?: string;
  overallStatus: "success" | "failure" | "pending" | "cancelled" | "no_runs";
  runs: Array<{
    name: string;
    status: "completed" | "in_progress" | "queued";
    conclusion: "success" | "failure" | "cancelled" | "skipped" | null;
    url: string;
    createdAt: string;
  }>;
}

export interface GitHubIssue {
  number: number;
  title: string;
  state: "open" | "closed";
  url: string;
  repo: string;
  author: string;
  assignees: string[];
  labels: string[];
  createdAt: string;
  body?: string;
}

export interface GitHubRepo {
  fullName: string;
  name: string;
  defaultBranch: string;
  isPrivate: boolean;
  updatedAt: string;
}

const GITHUB_API_BASE_URL = "https://api.github.com";
const MAX_REVIEW_BODY_LENGTH = 500;
const MAX_TEXT_BODY_LENGTH = 10_000;

export class GitHubClient {
  private readonly timeoutMs: number;

  constructor(config: GitHubClientConfig = {}) {
    this.timeoutMs = config.timeoutMs ?? 15_000;
  }

  isAuthenticated(session: SessionState): boolean {
    return Boolean(session.githubToken);
  }

  async listRepos(
    session: SessionState,
    options: { limit?: number } = {},
  ): Promise<GitHubRepo[]> {
    const limit = clampLimit(options.limit, 20, 100);
    const data = await this.githubRequest<unknown[]>(
      session,
      `/user/repos?sort=updated&per_page=${limit}`,
    );

    if (!Array.isArray(data)) {
      throw new Error("github_invalid_response");
    }

    return data.map((repo) => this.mapRepo(repo));
  }

  async listPRs(
    session: SessionState,
    options: { repo?: string; state?: "open" | "closed" | "all"; limit?: number } = {},
  ): Promise<GitHubPR[]> {
    const limit = clampLimit(options.limit, 10, 50);
    const state = options.state ?? "open";

    if (options.repo) {
      const repo = normalizeRepoName(options.repo);
      const data = await this.githubRequest<unknown[]>(
        session,
        `/repos/${encodeRepo(repo)}/pulls?state=${encodeURIComponent(state)}&per_page=${limit}`,
      );

      if (!Array.isArray(data)) {
        throw new Error("github_invalid_response");
      }

      return data.map((pullRequest) => this.mapPullRequest(pullRequest, repo));
    }

    const queryParts = ["is:pr", "author:@me"];
    if (state !== "all") {
      queryParts.push(`state:${state}`);
    }

    const search = await this.githubRequest<Record<string, unknown>>(
      session,
      `/search/issues?q=${encodeURIComponent(queryParts.join(" "))}&sort=updated&order=desc&per_page=${limit}`,
    );

    const items = Array.isArray(search.items) ? search.items : [];
    const pullRequests = await Promise.all(items.slice(0, limit).map(async (item) => {
      const record = asRecord(item);
      if (!record) return undefined;

      const detailUrl = stringValue(asRecord(record.pull_request)?.url);
      const repo = parseRepoName(
        stringValue(record.repository_url),
        stringValue(record.html_url),
      );
      const prNumber = numberValue(record.number);

      if (!detailUrl || !repo || prNumber === undefined) {
        return undefined;
      }

      try {
        const detail = await this.githubRequest<Record<string, unknown>>(session, detailUrl);
        return this.mapPullRequest(detail, repo);
      } catch (error) {
        logger.warn(`github: failed to fetch PR detail for ${repo}#${prNumber}: ${error instanceof Error ? error.message : "unknown"}`);
        return undefined;
      }
    }));

    return pullRequests.filter((pullRequest): pullRequest is GitHubPR => Boolean(pullRequest));
  }

  async getPR(
    session: SessionState,
    options: { repo: string; prNumber: number },
  ): Promise<GitHubPRDetail> {
    const repo = normalizeRepoName(options.repo);
    const prNumber = normalizePositiveInteger(options.prNumber, "github_invalid_pr_number");
    const detail = await this.githubRequest<Record<string, unknown>>(
      session,
      `/repos/${encodeRepo(repo)}/pulls/${prNumber}`,
    );
    const reviewSummary = await this.getReviews(session, { repo, prNumber });
    return this.mapPullRequestDetail(detail, repo, reviewSummary);
  }

  async getReviews(
    session: SessionState,
    options: { repo: string; prNumber: number },
  ): Promise<GitHubReviewSummary> {
    const repo = normalizeRepoName(options.repo);
    const prNumber = normalizePositiveInteger(options.prNumber, "github_invalid_pr_number");
    const [reviewsData, commentsData] = await Promise.all([
      this.githubRequest<unknown[]>(session, `/repos/${encodeRepo(repo)}/pulls/${prNumber}/reviews?per_page=100`),
      this.githubRequest<unknown[]>(session, `/repos/${encodeRepo(repo)}/pulls/${prNumber}/comments?per_page=100`),
    ]);

    if (!Array.isArray(reviewsData) || !Array.isArray(commentsData)) {
      throw new Error("github_invalid_response");
    }

    const latestReviewByUser = new Map<string, { state: GitHubReviewSummary["reviews"][number]["state"]; submittedAt: string }>();
    const reviews = reviewsData
      .map((review) => this.mapReview(review))
      .filter((review): review is GitHubReviewSummary["reviews"][number] => Boolean(review))
      .sort((left, right) => left.submittedAt.localeCompare(right.submittedAt));

    for (const review of reviews) {
      latestReviewByUser.set(review.reviewer, {
        state: review.state,
        submittedAt: review.submittedAt,
      });
    }

    const comments = commentsData
      .map((comment) => this.mapReviewComment(comment))
      .filter((comment): comment is GitHubReviewSummary["comments"][number] => Boolean(comment));

    return {
      prNumber,
      repo,
      overallState: summarizeOverallReviewState(Array.from(latestReviewByUser.values(), (entry) => entry.state)),
      reviews,
      comments,
    };
  }

  async createPR(
    session: SessionState,
    options: { repo: string; title: string; body?: string; head: string; base?: string },
  ): Promise<GitHubPR> {
    const repo = normalizeRepoName(options.repo);
    const created = await this.githubRequest<Record<string, unknown>>(
      session,
      `/repos/${encodeRepo(repo)}/pulls`,
      {
        method: "POST",
        body: {
          title: options.title,
          body: options.body ?? "",
          head: options.head,
          ...(options.base ? { base: options.base } : {}),
        },
      },
    );
    return this.mapPullRequest(created, repo);
  }

  async mergePR(
    session: SessionState,
    options: { repo: string; prNumber: number; mergeMethod?: "merge" | "squash" | "rebase" },
  ): Promise<{ merged: boolean; sha: string }> {
    const repo = normalizeRepoName(options.repo);
    const prNumber = normalizePositiveInteger(options.prNumber, "github_invalid_pr_number");
    const data = await this.githubRequest<Record<string, unknown>>(
      session,
      `/repos/${encodeRepo(repo)}/pulls/${prNumber}/merge`,
      {
        method: "PUT",
        body: {
          merge_method: options.mergeMethod ?? "merge",
        },
      },
    );

    return {
      merged: Boolean(data.merged),
      sha: stringValue(data.sha) ?? "",
    };
  }

  async getActionsStatus(
    session: SessionState,
    options: { repo: string; branch?: string; prNumber?: number },
  ): Promise<GitHubActionsStatus> {
    const repo = normalizeRepoName(options.repo);
    let branch = options.branch?.trim();

    if (!branch && options.prNumber !== undefined) {
      const detail = await this.getPR(session, { repo, prNumber: options.prNumber });
      branch = detail.branch;
    }

    const params = new URLSearchParams();
    params.set("per_page", "20");
    if (branch) {
      params.set("branch", branch);
    }

    const data = await this.githubRequest<Record<string, unknown>>(
      session,
      `/repos/${encodeRepo(repo)}/actions/runs?${params.toString()}`,
    );
    const workflowRuns = Array.isArray(data.workflow_runs) ? data.workflow_runs : [];
    const latestByName = new Map<string, GitHubActionsStatus["runs"][number]>();

    for (const workflowRun of workflowRuns) {
      const mapped = this.mapWorkflowRun(workflowRun);
      if (!mapped) continue;
      if (!latestByName.has(mapped.name)) {
        latestByName.set(mapped.name, mapped);
      }
    }

    const runs = Array.from(latestByName.values());

    return {
      repo,
      ...(branch ? { branch } : {}),
      overallStatus: summarizeWorkflowStatus(runs),
      runs,
    };
  }

  async listIssues(
    session: SessionState,
    options: { repo?: string; state?: "open" | "closed"; assignee?: "me" | string; limit?: number } = {},
  ): Promise<GitHubIssue[]> {
    const limit = clampLimit(options.limit, 10, 50);
    const state = options.state ?? "open";

    if (options.repo) {
      const repo = normalizeRepoName(options.repo);
      const params = new URLSearchParams();
      params.set("state", state);
      params.set("per_page", String(limit));
      if (options.assignee) {
        params.set("assignee", options.assignee === "me" ? "@me" : options.assignee);
      }

      const data = await this.githubRequest<unknown[]>(
        session,
        `/repos/${encodeRepo(repo)}/issues?${params.toString()}`,
      );

      if (!Array.isArray(data)) {
        throw new Error("github_invalid_response");
      }

      return data
        .filter((issue) => !asRecord(issue)?.pull_request)
        .map((issue) => this.mapIssue(issue, repo))
        .filter((issue): issue is GitHubIssue => Boolean(issue));
    }

    const queryParts = ["is:issue", `state:${state}`];
    if (options.assignee) {
      queryParts.push(`assignee:${options.assignee === "me" ? "@me" : options.assignee}`);
    }

    const search = await this.githubRequest<Record<string, unknown>>(
      session,
      `/search/issues?q=${encodeURIComponent(queryParts.join(" "))}&sort=updated&order=desc&per_page=${limit}`,
    );
    const items = Array.isArray(search.items) ? search.items : [];

    return items
      .map((issue) => this.mapIssue(issue))
      .filter((mapped): mapped is GitHubIssue => Boolean(mapped));
  }

  async createIssue(
    session: SessionState,
    options: { repo: string; title: string; body?: string; labels?: string[] },
  ): Promise<GitHubIssue> {
    const repo = normalizeRepoName(options.repo);
    const created = await this.githubRequest<Record<string, unknown>>(
      session,
      `/repos/${encodeRepo(repo)}/issues`,
      {
        method: "POST",
        body: {
          title: options.title,
          body: options.body ?? "",
          labels: Array.isArray(options.labels) ? options.labels : [],
        },
      },
    );
    const issue = this.mapIssue(created, repo);
    if (!issue) {
      throw new Error("github_invalid_response");
    }
    return issue;
  }

  private async githubRequest<T>(
    session: SessionState,
    pathOrUrl: string,
    options: { method?: string; body?: Record<string, unknown> } = {},
  ): Promise<T> {
    const token = session.githubToken?.trim();
    if (!token) {
      throw new Error("github_not_authenticated");
    }

    const url = pathOrUrl.startsWith("http://") || pathOrUrl.startsWith("https://")
      ? pathOrUrl
      : `${GITHUB_API_BASE_URL}${pathOrUrl}`;

    const response = await fetch(url, {
      method: options.method ?? "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "Content-Type": "application/json",
      },
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`github_http_${response.status}:${text.slice(0, 200)}`);
    }

    return (await response.json()) as T;
  }

  private mapRepo(repo: unknown): GitHubRepo {
    const record = asRecord(repo);
    if (!record) {
      throw new Error("github_invalid_response");
    }

    return {
      fullName: stringValue(record.full_name) ?? "",
      name: stringValue(record.name) ?? "",
      defaultBranch: stringValue(record.default_branch) ?? "",
      isPrivate: Boolean(record.private),
      updatedAt: stringValue(record.updated_at) ?? "",
    };
  }

  private mapPullRequest(pullRequest: unknown, repoOverride?: string): GitHubPR {
    const record = asRecord(pullRequest);
    if (!record) {
      throw new Error("github_invalid_response");
    }

    const state = stringValue(record.state) === "open"
      ? "open"
      : Boolean(record.merged_at)
        ? "merged"
        : "closed";
    const head = asRecord(record.head);
    const base = asRecord(record.base);
    const requestedReviewers = Array.isArray(record.requested_reviewers)
      ? record.requested_reviewers.map((reviewer) => stringValue(asRecord(reviewer)?.login)).filter(isString)
      : [];

    return {
      number: numberValue(record.number) ?? 0,
      title: stringValue(record.title) ?? "",
      state,
      url: stringValue(record.html_url) ?? "",
      repo: repoOverride ?? parseRepoName(undefined, stringValue(record.html_url)) ?? "",
      branch: stringValue(head?.ref) ?? "",
      baseBranch: stringValue(base?.ref) ?? "",
      author: stringValue(asRecord(record.user)?.login) ?? "",
      createdAt: stringValue(record.created_at) ?? "",
      updatedAt: stringValue(record.updated_at) ?? "",
      isDraft: Boolean(record.draft),
      reviewState: requestedReviewers.length > 0 ? "review_required" : undefined,
    };
  }

  private mapPullRequestDetail(
    pullRequest: unknown,
    repo: string,
    reviewSummary: GitHubReviewSummary,
  ): GitHubPRDetail {
    const record = asRecord(pullRequest);
    if (!record) {
      throw new Error("github_invalid_response");
    }

    const summary = this.mapPullRequest(record, repo);
    const requestedReviewers = Array.isArray(record.requested_reviewers)
      ? record.requested_reviewers.map((reviewer) => stringValue(asRecord(reviewer)?.login)).filter(isString)
      : [];
    const reviewers = Array.from(new Set([
      ...requestedReviewers,
      ...reviewSummary.reviews.map((review) => review.reviewer),
    ]));

    return {
      ...summary,
      body: truncate(stringValue(record.body) ?? "", MAX_TEXT_BODY_LENGTH),
      additions: numberValue(record.additions) ?? 0,
      deletions: numberValue(record.deletions) ?? 0,
      changedFiles: numberValue(record.changed_files) ?? 0,
      mergeable: typeof record.mergeable === "boolean" ? record.mergeable : null,
      reviewers,
      reviewState: summarizePullRequestReviewState(reviewSummary.overallState, requestedReviewers.length > 0),
    };
  }

  private mapReview(review: unknown): GitHubReviewSummary["reviews"][number] | undefined {
    const record = asRecord(review);
    if (!record) {
      return undefined;
    }

    const state = normalizeReviewState(stringValue(record.state));
    const reviewer = stringValue(asRecord(record.user)?.login);
    const submittedAt = stringValue(record.submitted_at) ?? "";
    if (!state || !reviewer || !submittedAt) {
      return undefined;
    }

    return {
      reviewer,
      state,
      body: truncate(stringValue(record.body) ?? "", MAX_REVIEW_BODY_LENGTH),
      submittedAt,
    };
  }

  private mapReviewComment(comment: unknown): GitHubReviewSummary["comments"][number] | undefined {
    const record = asRecord(comment);
    if (!record) {
      return undefined;
    }

    const reviewer = stringValue(asRecord(record.user)?.login);
    const createdAt = stringValue(record.created_at) ?? "";
    if (!reviewer || !createdAt) {
      return undefined;
    }

    const line = numberValue(record.line);

    return {
      reviewer,
      body: truncate(stringValue(record.body) ?? "", MAX_REVIEW_BODY_LENGTH),
      ...(stringValue(record.path) ? { path: stringValue(record.path) } : {}),
      ...(line !== undefined ? { line } : {}),
      createdAt,
    };
  }

  private mapWorkflowRun(workflowRun: unknown): GitHubActionsStatus["runs"][number] | undefined {
    const record = asRecord(workflowRun);
    if (!record) {
      return undefined;
    }

    const name = stringValue(record.name);
    const url = stringValue(record.html_url);
    const createdAt = stringValue(record.created_at);
    if (!name || !url || !createdAt) {
      return undefined;
    }

    return {
      name,
      status: normalizeWorkflowRunStatus(stringValue(record.status)),
      conclusion: normalizeWorkflowConclusion(stringValue(record.conclusion)),
      url,
      createdAt,
    };
  }

  private mapIssue(issue: unknown, repoOverride?: string): GitHubIssue | undefined {
    const record = asRecord(issue);
    if (!record || record.pull_request) {
      return undefined;
    }

    const repo = repoOverride ?? parseRepoName(
      stringValue(record.repository_url),
      stringValue(record.html_url),
    );
    if (!repo) {
      return undefined;
    }

    const assignees = Array.isArray(record.assignees)
      ? record.assignees.map((assignee) => stringValue(asRecord(assignee)?.login)).filter(isString)
      : [];
    const labels = Array.isArray(record.labels)
      ? record.labels.map((label) => stringValue(asRecord(label)?.name)).filter(isString)
      : [];
    const state = stringValue(record.state) === "closed" ? "closed" : "open";

    return {
      number: numberValue(record.number) ?? 0,
      title: stringValue(record.title) ?? "",
      state,
      url: stringValue(record.html_url) ?? "",
      repo,
      author: stringValue(asRecord(record.user)?.login) ?? "",
      assignees,
      labels,
      createdAt: stringValue(record.created_at) ?? "",
      body: truncate(stringValue(record.body) ?? "", MAX_TEXT_BODY_LENGTH),
    };
  }
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isString(value: string | undefined): value is string {
  return typeof value === "string";
}

function clampLimit(value: number | undefined, defaultValue: number, maxValue: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return defaultValue;
  }
  return Math.max(1, Math.min(maxValue, Math.trunc(value)));
}

function normalizePositiveInteger(value: number, errorMessage: string): number {
  const normalized = Math.trunc(value);
  if (!Number.isFinite(normalized) || normalized <= 0) {
    throw new Error(errorMessage);
  }
  return normalized;
}

function normalizeRepoName(repo: string): string {
  const normalized = repo.trim();
  if (!normalized.includes("/")) {
    throw new Error("github_invalid_repo");
  }
  return normalized;
}

function encodeRepo(repo: string): string {
  const [owner, name] = repo.split("/", 2);
  return `${encodeURIComponent(owner)}\/${encodeURIComponent(name)}`;
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, maxLength - 1)}…`;
}

function parseRepoName(repositoryUrl?: string, htmlUrl?: string): string | undefined {
  const parsedFromApi = parseRepoFromUrl(repositoryUrl);
  if (parsedFromApi) {
    return parsedFromApi;
  }
  return parseRepoFromUrl(htmlUrl);
}

function parseRepoFromUrl(url?: string): string | undefined {
  if (!url) {
    return undefined;
  }

  try {
    const parsed = new URL(url);
    const parts = parsed.pathname.split("/").filter(Boolean);

    if (parsed.hostname === "api.github.com" && parts[0] === "repos" && parts.length >= 3) {
      return `${parts[1]}/${parts[2]}`;
    }

    if (parts.length >= 2) {
      return `${parts[0]}/${parts[1]}`;
    }
  } catch {
    return undefined;
  }

  return undefined;
}

function normalizeReviewState(state?: string): GitHubReviewSummary["reviews"][number]["state"] | undefined {
  switch (state?.toUpperCase()) {
    case "APPROVED":
      return "approved";
    case "CHANGES_REQUESTED":
      return "changes_requested";
    case "COMMENTED":
      return "commented";
    case "DISMISSED":
      return "dismissed";
    default:
      return undefined;
  }
}

function summarizeOverallReviewState(
  states: Array<GitHubReviewSummary["reviews"][number]["state"]>,
): GitHubReviewSummary["overallState"] {
  if (states.includes("changes_requested")) {
    return "changes_requested";
  }
  if (states.includes("approved")) {
    return "approved";
  }
  if (states.includes("commented") || states.includes("dismissed")) {
    return "commented";
  }
  return "pending";
}

function summarizePullRequestReviewState(
  overallState: GitHubReviewSummary["overallState"],
  hasRequestedReviewers: boolean,
): GitHubPR["reviewState"] {
  if (hasRequestedReviewers && overallState === "pending") {
    return "review_required";
  }
  if (overallState === "approved" || overallState === "changes_requested" || overallState === "pending") {
    return overallState;
  }
  return undefined;
}

function normalizeWorkflowRunStatus(status?: string): GitHubActionsStatus["runs"][number]["status"] {
  switch (status) {
    case "completed":
      return "completed";
    case "in_progress":
      return "in_progress";
    default:
      return "queued";
  }
}

function normalizeWorkflowConclusion(
  conclusion?: string,
): GitHubActionsStatus["runs"][number]["conclusion"] {
  switch (conclusion) {
    case "success":
    case "failure":
    case "cancelled":
    case "skipped":
      return conclusion;
    default:
      return null;
  }
}

function summarizeWorkflowStatus(
  runs: GitHubActionsStatus["runs"],
): GitHubActionsStatus["overallStatus"] {
  if (runs.length === 0) {
    return "no_runs";
  }
  if (runs.some((run) => run.status !== "completed")) {
    return "pending";
  }
  if (runs.some((run) => run.conclusion === "failure")) {
    return "failure";
  }
  if (runs.some((run) => run.conclusion === "cancelled")) {
    return "cancelled";
  }
  return "success";
}

import crypto from "node:crypto";
import { makeEvent } from "../../core/events.js";
import { SessionState, ToolDefinition } from "../../core/types.js";
import { listChecksForPr, summarizeChecks, waitForChecksTerminal } from "../ci/checks.js";
import { diagnoseCiFailure } from "../ci/diagnose.js";
import { ContextBudget, ContextConstraintSet, ContextEngine, FailureSignals } from "../context/contextEngine.js";
import { EmbeddingsIndexStore } from "../embeddings/indexStore.js";
import { GitHubClient } from "../github/githubClient.js";
import { parseRepoRef, sanitizeBranchName } from "../github/repo.js";
import { applyPatchToBranch } from "../patch/applyPatch.js";
import {
  AnthropicPatchGenerationProvider,
  DeterministicFallbackPatchProvider,
  PatchGenerationProvider,
} from "../patch/generator.js";
import { PatchConstraints, validateUnifiedDiff } from "../patch/validator.js";
import { checkMergePolicy } from "../policy/policyEngine.js";
import { findPreviewUrl } from "../preview/previewFinder.js";
import { RunnerProvider, StubRunnerProvider } from "../runner/runnerProvider.js";
import { InMemoryRunStore, RunStore, Stage3RunRecord } from "../storage/runStore.js";
import { StubWebQAProvider, WebQAProvider } from "../webqa/provider.js";
import { ToolRegistry } from "./registry.js";
import { ToolExecutionContext, ToolRegistration } from "./types.js";

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function parseStringArray(value: unknown): string[] {
  return asArray(value).map((item) => asString(item)).filter((item): item is string => Boolean(item));
}

function parseRepoFromArgs(session: SessionState, args: Record<string, unknown>): string {
  const repo = asString(args.repo) ?? session.selectedRepo;
  if (!repo) {
    throw new Error("repo_not_selected");
  }
  session.selectedRepo = repo;
  return repo;
}

function requireGitHubClient(session: SessionState): GitHubClient {
  if (!session.githubToken) {
    throw new Error("missing_github_token");
  }
  return new GitHubClient(session.githubToken);
}

function emitArtifact(
  context: ToolExecutionContext,
  title: string,
  body: string,
  data: Record<string, unknown>,
): void {
  context.emit(makeEvent("assistant.ui.patch", context.session.sessionId, {
    patch: JSON.stringify({
      stage: "stage3",
      title,
      body,
      data,
    }),
  }));
}

function emitStatus(context: ToolExecutionContext, detail: string): void {
  context.emit(makeEvent("agent.status", context.session.sessionId, {
    status: "stage3",
    detail,
  }));
}

interface Stage3ToolDeps {
  embeddings: EmbeddingsIndexStore;
  contextEngine: ContextEngine;
  runStore: RunStore;
  patchProvider: PatchGenerationProvider;
  webqaProvider: WebQAProvider;
  runnerProvider: RunnerProvider;
}

export function createStage3Dependencies(config: {
  anthropicApiKey?: string;
  anthropicModel: string;
}): Stage3ToolDeps {
  const patchProvider = config.anthropicApiKey
    ? new AnthropicPatchGenerationProvider(config.anthropicApiKey, config.anthropicModel)
    : new DeterministicFallbackPatchProvider();

  const embeddings = new EmbeddingsIndexStore({
    name: "hash-embeddings",
    embed: async (text: string) => {
      const vec = new Array<number>(128).fill(0);
      const tokens = text.toLowerCase().split(/[^a-z0-9_]+/).filter(Boolean);
      for (const token of tokens) {
        let hash = 0;
        for (let i = 0; i < token.length; i += 1) {
          hash = (hash * 31 + token.charCodeAt(i)) >>> 0;
        }
        const idx = hash % vec.length;
        vec[idx] += 1;
      }
      const norm = Math.sqrt(vec.reduce((acc, value) => acc + value * value, 0)) || 1;
      return vec.map((value) => value / norm);
    },
  });

  return {
    embeddings,
    contextEngine: new ContextEngine(embeddings),
    runStore: new InMemoryRunStore(),
    patchProvider,
    webqaProvider: new StubWebQAProvider(),
    runnerProvider: new StubRunnerProvider(),
  };
}

function patchConstraintsFromArgs(args: Record<string, unknown>): PatchConstraints {
  return {
    allowedPaths: parseStringArray(args.allowedPaths),
    noReformat: asBoolean(args.noReformat) ?? true,
    maxDiffLines: asNumber(args.maxDiffLines) ?? 250,
    allowLockfiles: asBoolean(args.allowLockfiles) ?? false,
  };
}

function parseFailureSignals(value: unknown): FailureSignals {
  const obj = asObject(value);
  const failingTests = asArray(obj.failingTests)
    .map((item) => asObject(item))
    .map((item) => ({
      name: asString(item.name) ?? "",
      file: asString(item.file),
      line: asNumber(item.line),
    }))
    .filter((test) => Boolean(test.name));

  return {
    signature: asString(obj.signature),
    stackPaths: parseStringArray(obj.stackPaths),
    keyErrors: parseStringArray(obj.keyErrors),
    suggestedQueries: parseStringArray(obj.suggestedQueries),
    logsExcerpt: asString(obj.logsExcerpt),
    failingTests,
  };
}

function parseContextConstraints(value: unknown): ContextConstraintSet {
  const obj = asObject(value);
  return {
    allowedPaths: parseStringArray(obj.allowedPaths),
    noReformat: asBoolean(obj.noReformat) ?? true,
    maxDiffLines: asNumber(obj.maxDiffLines) ?? 250,
    mustFixSignature: asString(obj.mustFixSignature),
  };
}

function parseContextBudget(value: unknown): ContextBudget {
  const obj = asObject(value);
  return {
    maxChars: asNumber(obj.maxChars) ?? 45_000,
    topFullFiles: asNumber(obj.topFullFiles) ?? 4,
    topSnippets: asNumber(obj.topSnippets) ?? 10,
  };
}

async function ensureRunRecord(args: {
  context: ToolExecutionContext;
  github: GitHubClient;
  repo: string;
  runStore: RunStore;
}): Promise<Stage3RunRecord> {
  const { context, github, repo, runStore } = args;
  const existingRunId = context.session.activeRunId;
  if (existingRunId) {
    const existing = await runStore.get(existingRunId);
    if (existing) {
      return existing;
    }
  }

  const parsedRepo = parseRepoRef(repo);
  const repoInfo = await github.getRepo(parsedRepo);
  const runId = crypto.randomUUID();
  const branch = sanitizeBranchName(`abyss/stage3/${runId.slice(0, 8)}`);

  try {
    await github.createBranch(parsedRepo, repoInfo.defaultBranch, branch);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_branch_error";
    if (!message.includes("Reference already exists")) {
      throw error;
    }
  }

  const record: Stage3RunRecord = {
    runId,
    sessionId: context.session.sessionId,
    repo,
    branch,
    baseRef: repoInfo.defaultBranch,
    status: "created",
    iteration: 0,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
  await runStore.put(record);
  context.session.activeRunId = runId;
  return record;
}

function updateRun(record: Stage3RunRecord, patch: Partial<Stage3RunRecord>): Stage3RunRecord {
  return {
    ...record,
    ...patch,
    updatedAt: new Date().toISOString(),
  };
}

export function buildStage3Registry(deps: Stage3ToolDeps): ToolRegistry {
  const registry = new ToolRegistry();

  const clientTools: ToolRegistration[] = [
    {
      definition: {
        name: "convo.appendMessage",
        description: "Append a message to iOS conversation transcript.",
        input_schema: {
          type: "object",
          properties: {
            role: { type: "string" },
            text: { type: "string" },
            isPartial: { type: "boolean" },
          },
          required: ["role", "text"],
        },
      },
      target: "client",
      sideEffect: "write",
    },
    {
      definition: {
        name: "convo.setState",
        description: "Set iOS app state indicator.",
        input_schema: {
          type: "object",
          properties: {
            state: { type: "string" },
          },
          required: ["state"],
        },
      },
      target: "client",
      sideEffect: "write",
    },
    {
      definition: {
        name: "tts.speak",
        description: "Speak text on iOS.",
        input_schema: {
          type: "object",
          properties: {
            text: { type: "string" },
          },
          required: ["text"],
        },
      },
      target: "client",
      sideEffect: "execute",
    },
    {
      definition: {
        name: "repositories.list",
        description: "List repositories available via Cursor Cloud (optional fallback).",
        input_schema: {
          type: "object",
          properties: {},
        },
      },
      target: "client",
      sideEffect: "read",
    },
    {
      definition: {
        name: "agent.spawn",
        description: "Launch a Cursor cloud agent (optional fallback executor).",
        input_schema: {
          type: "object",
          properties: {
            prompt: { type: "string" },
            repository: { type: "string" },
            ref: { type: "string" },
            prUrl: { type: "string" },
            model: { type: "string" },
            autoCreatePr: { type: "boolean" },
            autoBranch: { type: "boolean" },
            skipReviewerRequest: { type: "boolean" },
            branchName: { type: "string" },
          },
          required: ["prompt"],
        },
      },
      target: "client",
      sideEffect: "execute",
    },
    {
      definition: {
        name: "agent.status",
        description: "Get status of a Cursor cloud agent.",
        input_schema: {
          type: "object",
          properties: {
            id: { type: "string" },
          },
          required: ["id"],
        },
      },
      target: "client",
      sideEffect: "read",
    },
    {
      definition: {
        name: "agent.cancel",
        description: "Cancel a Cursor cloud agent.",
        input_schema: {
          type: "object",
          properties: {
            id: { type: "string" },
          },
          required: ["id"],
        },
      },
      target: "client",
      sideEffect: "execute",
    },
    {
      definition: {
        name: "agent.followup",
        description: "Send follow-up instruction to a Cursor cloud agent.",
        input_schema: {
          type: "object",
          properties: {
            id: { type: "string" },
            prompt: { type: "string" },
          },
          required: ["id", "prompt"],
        },
      },
      target: "client",
      sideEffect: "execute",
    },
    {
      definition: {
        name: "agent.list",
        description: "List Cursor cloud agents.",
        input_schema: {
          type: "object",
          properties: {
            limit: { type: "number" },
            cursor: { type: "string" },
            prUrl: { type: "string" },
          },
        },
      },
      target: "client",
      sideEffect: "read",
    },
  ];

  const serverTools: ToolRegistration[] = [
    {
      definition: {
        name: "github.repo.list",
        description: "List repositories for the authenticated GitHub user.",
        input_schema: {
          type: "object",
          properties: {
            limit: { type: "number" },
          },
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const limit = asNumber(args.limit) ?? 50;
        const repos = await github.listRepos(limit);
        return { repos };
      },
    },
    {
      definition: {
        name: "github.repo.getDefaultBranch",
        description: "Get default branch for a repository.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
          },
          required: ["repo"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const parsed = parseRepoRef(repo);
        const info = await github.getRepo(parsed);
        return {
          repo,
          defaultBranch: info.defaultBranch,
        };
      },
    },
    {
      definition: {
        name: "github.file.get",
        description: "Get a file at a specific ref.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
            path: { type: "string" },
          },
          required: ["repo", "ref", "path"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        const path = asString(args.path);
        if (!ref || !path) {
          throw new Error("missing_ref_or_path");
        }
        const file = await github.getFile(parseRepoRef(repo), ref, path);
        return {
          content: file.content,
          sha: file.sha,
        };
      },
    },
    {
      definition: {
        name: "github.tree.list",
        description: "List repository tree entries for a ref.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
            path: { type: "string" },
          },
          required: ["repo", "ref"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        const pathPrefix = asString(args.path);
        if (!ref) {
          throw new Error("missing_ref");
        }
        const entries = await github.listTree(parseRepoRef(repo), ref);
        const filtered = pathPrefix
          ? entries.filter((entry) => entry.path.startsWith(pathPrefix))
          : entries;
        return { entries: filtered };
      },
    },
    {
      definition: {
        name: "github.search.code",
        description: "Search code in the selected repo.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            query: { type: "string" },
            ref: { type: "string" },
          },
          required: ["repo", "query"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const query = asString(args.query);
        if (!query) {
          throw new Error("missing_query");
        }
        const matches = await github.searchCode(parseRepoRef(repo), query);
        return { matches };
      },
    },
    {
      definition: {
        name: "github.branch.create",
        description: "Create a branch from a base branch.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            baseRef: { type: "string" },
            newBranch: { type: "string" },
          },
          required: ["repo", "baseRef", "newBranch"],
        },
      },
      target: "server",
      sideEffect: "write",
      supportsIdempotency: true,
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const baseRef = asString(args.baseRef);
        const newBranch = asString(args.newBranch);
        if (!baseRef || !newBranch) {
          throw new Error("missing_base_or_branch");
        }
        const result = await github.createBranch(parseRepoRef(repo), baseRef, newBranch);
        return { ref: result.ref };
      },
    },
    {
      definition: {
        name: "github.pr.openOrUpdate",
        description: "Open or update a pull request.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            base: { type: "string" },
            head: { type: "string" },
            title: { type: "string" },
            body: { type: "string" },
            draft: { type: "boolean" },
          },
          required: ["repo", "base", "head", "title", "body"],
        },
      },
      target: "server",
      sideEffect: "write",
      supportsIdempotency: true,
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const base = asString(args.base);
        const head = asString(args.head);
        const title = asString(args.title);
        const body = asString(args.body);
        const draft = asBoolean(args.draft);
        if (!base || !head || !title || !body) {
          throw new Error("missing_pr_fields");
        }
        const pr = await github.openOrUpdatePr({
          ref: parseRepoRef(repo),
          base,
          head,
          title,
          body,
          draft,
        });
        context.session.lastPrNumber = pr.number;
        context.session.lastPrUrl = pr.url;
        emitArtifact(context, "Pull Request", `PR #${pr.number} ready`, {
          prNumber: pr.number,
          prUrl: pr.url,
          repo,
        });
        return {
          prNumber: pr.number,
          url: pr.url,
        };
      },
    },
    {
      definition: {
        name: "github.pr.diff",
        description: "Get current PR diff files.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
          },
          required: ["repo", "prNumber"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        if (!prNumber) {
          throw new Error("missing_pr_number");
        }
        const files = await github.listPrFiles(parseRepoRef(repo), prNumber);
        return { files };
      },
    },
    {
      definition: {
        name: "github.pr.comment",
        description: "Add a comment to PR.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
            body: { type: "string" },
          },
          required: ["repo", "prNumber", "body"],
        },
      },
      target: "server",
      sideEffect: "write",
      supportsIdempotency: true,
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber);
        const body = asString(args.body);
        if (!prNumber || !body) {
          throw new Error("missing_comment_fields");
        }
        const comment = await github.commentOnPr(parseRepoRef(repo), prNumber, body);
        return {
          commentId: comment.commentId,
        };
      },
    },
    {
      definition: {
        name: "github.pr.merge",
        description: "Merge pull request.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
            method: { type: "string" },
          },
          required: ["repo", "prNumber", "method"],
        },
      },
      target: "server",
      sideEffect: "write",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        const method = asString(args.method) ?? "squash";
        if (!prNumber) {
          throw new Error("missing_pr_number");
        }
        const merged = await github.mergePr(parseRepoRef(repo), prNumber, method);
        return merged;
      },
    },
    {
      definition: {
        name: "github.checks.list",
        description: "List checks for PR or ref.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            refOrPr: { type: "string" },
            prNumber: { type: "number" },
          },
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;

        if (prNumber) {
          const checks = await listChecksForPr(github, repo, prNumber);
          return { checks };
        }

        const refOrPr = asString(args.refOrPr);
        if (!refOrPr) {
          throw new Error("missing_ref_or_pr");
        }

        const parsedRepo = parseRepoRef(repo);
        const checks = await github.listChecksBySha(parsedRepo, refOrPr);
        return { checks };
      },
    },
    {
      definition: {
        name: "ci.checks.list",
        description: "List CI checks for PR.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
          },
          required: ["repo", "prNumber"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        if (!prNumber) {
          throw new Error("missing_pr_number");
        }
        const checks = await listChecksForPr(github, repo, prNumber);
        const summary = summarizeChecks(checks);
        emitArtifact(context, "CI Summary", summary.summary, {
          checks,
          pass: summary.pass,
        });
        return { checks };
      },
    },
    {
      definition: {
        name: "ci.checks.logs",
        description: "Get excerpt for a CI check run.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            checkRunId: { type: "number" },
          },
          required: ["repo", "checkRunId"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const checkRunId = asNumber(args.checkRunId);
        if (!checkRunId) {
          throw new Error("missing_check_run_id");
        }

        const check = await github.getCheckRun(parseRepoRef(repo), checkRunId);
        const excerpt = [check.outputTitle, check.outputSummary, check.outputText]
          .filter(Boolean)
          .join("\n")
          .slice(0, 12_000);

        return {
          excerpt,
          url: check.detailsUrl,
        };
      },
    },
    {
      definition: {
        name: "ci.checks.rerun",
        description: "Request rerun for check run.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            checkRunId: { type: "number" },
          },
          required: ["repo", "checkRunId"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const checkRunId = asNumber(args.checkRunId);
        if (!checkRunId) {
          throw new Error("missing_check_run_id");
        }
        await github.rerunCheck(parseRepoRef(repo), checkRunId);
        return { started: true };
      },
    },
    {
      definition: {
        name: "ci.workflow.dispatch",
        description: "Dispatch a workflow file.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            workflow: { type: "string" },
            ref: { type: "string" },
            inputs: { type: "object" },
          },
          required: ["repo", "workflow", "ref"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const workflow = asString(args.workflow);
        const ref = asString(args.ref);
        const inputs = asObject(args.inputs);
        if (!workflow || !ref) {
          throw new Error("missing_workflow_or_ref");
        }

        const normalizedInputs: Record<string, string> = {};
        for (const [key, value] of Object.entries(inputs)) {
          normalizedInputs[key] = typeof value === "string" ? value : JSON.stringify(value);
        }

        await github.workflowDispatch(parseRepoRef(repo), workflow, ref, normalizedInputs);
        return {
          runId: 0,
        };
      },
    },
    {
      definition: {
        name: "ci.workflow.status",
        description: "Get workflow run status.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            runId: { type: "number" },
          },
          required: ["repo", "runId"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const runId = asNumber(args.runId);
        if (!runId) {
          throw new Error("missing_run_id");
        }
        const status = await github.workflowStatus(parseRepoRef(repo), runId);
        return status;
      },
    },
    {
      definition: {
        name: "diagnose.ciFailure",
        description: "Diagnose CI failure from log excerpt.",
        input_schema: {
          type: "object",
          properties: {
            logsExcerpt: { type: "string" },
          },
          required: ["logsExcerpt"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (_context, args) => {
        const logsExcerpt = asString(args.logsExcerpt);
        if (!logsExcerpt) {
          throw new Error("missing_logs_excerpt");
        }
        return diagnoseCiFailure(logsExcerpt);
      },
    },
    {
      definition: {
        name: "embeddings.indexRepo",
        description: "Index repository files for embeddings retrieval.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
          },
          required: ["repo", "ref"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        if (!ref) {
          throw new Error("missing_ref");
        }

        const tree = await github.listTree(parseRepoRef(repo), ref);
        const textFiles = tree
          .filter((entry) => entry.type === "blob")
          .filter((entry) => !/(^|\/)node_modules\//.test(entry.path))
          .filter((entry) => !/(^|\/)dist\//.test(entry.path))
          .filter((entry) => /(\.ts|\.tsx|\.js|\.jsx|\.json|\.md|\.go|\.py|\.java|\.swift|\.kt|\.rb|\.rs|\.yml|\.yaml)$/.test(entry.path))
          .slice(0, 250);

        const files: Array<{ path: string; content: string }> = [];
        for (const entry of textFiles) {
          const file = await github.getFile(parseRepoRef(repo), ref, entry.path);
          files.push({ path: entry.path, content: file.content.slice(0, 30_000) });
        }

        const indexed = await deps.embeddings.indexFiles(repo, ref, files);
        return {
          status: "indexed",
          indexedChunks: indexed.indexedChunks,
          files: files.length,
        };
      },
    },
    {
      definition: {
        name: "embeddings.updateChangedFiles",
        description: "Incrementally update embeddings index for changed files.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
            changedPaths: { type: "array" },
          },
          required: ["repo", "ref", "changedPaths"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        const changedPaths = parseStringArray(args.changedPaths);
        if (!ref) {
          throw new Error("missing_ref");
        }

        const files: Array<{ path: string; content: string }> = [];
        for (const path of changedPaths) {
          const file = await github.getFile(parseRepoRef(repo), ref, path);
          files.push({ path, content: file.content.slice(0, 30_000) });
        }

        const indexed = await deps.embeddings.indexFiles(repo, ref, files);
        return {
          status: "updated",
          indexedChunks: indexed.indexedChunks,
          files: files.length,
        };
      },
    },
    {
      definition: {
        name: "embeddings.query",
        description: "Query indexed embeddings chunks.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            query: { type: "string" },
            ref: { type: "string" },
            topK: { type: "number" },
          },
          required: ["repo", "query", "ref"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        const query = asString(args.query);
        const topK = asNumber(args.topK) ?? 8;
        if (!ref || !query) {
          throw new Error("missing_ref_or_query");
        }

        const chunks = await deps.embeddings.query(repo, ref, query, topK);
        return { chunks };
      },
    },
    {
      definition: {
        name: "context.buildBundle",
        description: "Build context bundle for patch generation using hybrid retrieval.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
            goal: { type: "string" },
            failureSignals: { type: "object" },
            constraints: { type: "object" },
            budget: { type: "object" },
          },
          required: ["repo", "ref", "goal", "failureSignals", "constraints", "budget"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const ref = asString(args.ref);
        const goal = asString(args.goal);
        if (!ref || !goal) {
          throw new Error("missing_ref_or_goal");
        }
        const failureSignals = parseFailureSignals(args.failureSignals);
        const constraints = parseContextConstraints(args.constraints);
        const budget = parseContextBudget(args.budget);

        const bundle = await deps.contextEngine.buildBundle({
          github,
          repo,
          ref,
          goal,
          failureSignals,
          constraints,
          budget,
        });
        return { bundle };
      },
    },
    {
      definition: {
        name: "patch.generateDiff",
        description: "Generate a safe unified diff from context bundle.",
        input_schema: {
          type: "object",
          properties: {
            provider: { type: "string" },
            model: { type: "string" },
            contextBundle: { type: "object" },
            constraints: { type: "object" },
          },
          required: ["contextBundle", "constraints"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const contextBundle = asObject(args.contextBundle) as unknown as {
          goal: string;
          failureSummary: string;
          logsExcerpt: string;
          fullFiles: Array<{ path: string; content: string }>;
          snippets: Array<{ path: string; startLine: number; endLine: number; text: string }>;
          configs: Array<{ path: string; content: string }>;
          currentPrDiff?: Array<{ path: string; patch: string }>;
          constraints: ContextConstraintSet;
        };

        const constraints = asObject(args.constraints);

        const response = await deps.patchProvider.generateDiff({
          provider: asString(args.provider),
          model: asString(args.model),
          contextBundle,
          constraints: {
            maxDiffLines: asNumber(constraints.maxDiffLines),
            allowedPaths: parseStringArray(constraints.allowedPaths),
            noReformat: asBoolean(constraints.noReformat),
            mustFixSignature: asString(constraints.mustFixSignature),
          },
        });

        return response;
      },
    },
    {
      definition: {
        name: "patch.validate",
        description: "Validate unified diff against constraints.",
        input_schema: {
          type: "object",
          properties: {
            unifiedDiff: { type: "string" },
            constraints: { type: "object" },
          },
          required: ["unifiedDiff", "constraints"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (_context, args) => {
        const unifiedDiff = asString(args.unifiedDiff);
        const constraints = patchConstraintsFromArgs(asObject(args.constraints));
        if (!unifiedDiff) {
          throw new Error("missing_unified_diff");
        }
        return validateUnifiedDiff(unifiedDiff, constraints);
      },
    },
    {
      definition: {
        name: "github.applyPatchToBranch",
        description: "Apply unified diff to a branch and commit.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            branch: { type: "string" },
            unifiedDiff: { type: "string" },
            commitMessage: { type: "string" },
          },
          required: ["repo", "branch", "unifiedDiff"],
        },
      },
      target: "server",
      sideEffect: "write",
      supportsIdempotency: true,
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const branch = asString(args.branch);
        const unifiedDiff = asString(args.unifiedDiff);
        const commitMessage = asString(args.commitMessage) ?? "chore: apply patch";

        if (!branch || !unifiedDiff) {
          throw new Error("missing_branch_or_diff");
        }

        const result = await applyPatchToBranch({
          github,
          repo,
          branch,
          unifiedDiff,
          commitMessage,
        });

        emitArtifact(context, "Patch Applied", `${result.changedFiles.length} files changed`, {
          commitSha: result.commitSha,
          changedFiles: result.changedFiles,
        });

        return result;
      },
    },
    {
      definition: {
        name: "preview.findUrl",
        description: "Find preview deployment URL for a PR.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
          },
          required: ["repo", "prNumber"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        if (!prNumber) {
          throw new Error("missing_pr_number");
        }

        const checks = await listChecksForPr(github, repo, prNumber);
        const preview = await findPreviewUrl({
          github,
          repo,
          prNumber,
          checks,
        });

        emitArtifact(context, "Preview URL", preview.url, preview);
        return preview;
      },
    },
    {
      definition: {
        name: "webqa.run",
        description: "Run web validation flow against preview URL.",
        input_schema: {
          type: "object",
          properties: {
            url: { type: "string" },
            flowSpec: { type: "object" },
            assertions: { type: "array" },
            budget: { type: "object" },
          },
          required: ["url", "flowSpec", "assertions"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const url = asString(args.url);
        if (!url) {
          throw new Error("missing_url");
        }

        const flowSpecObj = asObject(args.flowSpec);
        const flowSpec = {
          name: asString(flowSpecObj.name) ?? "web-flow",
          steps: asArray(flowSpecObj.steps).map((step) => {
            const obj = asObject(step);
            const action = asString(obj.action);
            if (!action || !["navigate", "click", "type", "assertTextVisible"].includes(action)) {
              return {
                action: "navigate" as const,
              };
            }
            return {
              action: action as "navigate" | "click" | "type" | "assertTextVisible",
              selector: asString(obj.selector),
              value: asString(obj.value),
            };
          }),
        };

        const assertions = parseStringArray(args.assertions);
        return deps.webqaProvider.run(url, flowSpec, assertions);
      },
    },
    {
      definition: {
        name: "webqa.status",
        description: "Get webqa run status.",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
          },
          required: ["runId"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (_context, args) => {
        const runId = asString(args.runId);
        if (!runId) {
          throw new Error("missing_run_id");
        }
        return deps.webqaProvider.status(runId);
      },
    },
    {
      definition: {
        name: "webqa.artifacts",
        description: "Get artifacts for a webqa run.",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
          },
          required: ["runId"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const runId = asString(args.runId);
        if (!runId) {
          throw new Error("missing_run_id");
        }
        const artifacts = await deps.webqaProvider.artifacts(runId);
        emitArtifact(context, "Web Validation", artifacts.pass ? "Web flow passed" : "Web flow failed", artifacts as unknown as Record<string, unknown>);
        return artifacts as unknown as Record<string, unknown>;
      },
    },
    {
      definition: {
        name: "policy.checkMerge",
        description: "Evaluate merge policy blockers.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
            requireWebQA: { type: "boolean" },
            requireChecksGreen: { type: "boolean" },
            webqaPass: { type: "boolean" },
          },
          required: ["repo", "prNumber"],
        },
      },
      target: "server",
      sideEffect: "read",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        const prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        if (!prNumber) {
          throw new Error("missing_pr_number");
        }

        const checks = await listChecksForPr(github, repo, prNumber);
        const policy = checkMergePolicy({
          checks: checks.map((check) => ({
            name: check.name,
            status: check.status,
            conclusion: check.conclusion,
          })),
          requireWebQA: asBoolean(args.requireWebQA) ?? true,
          requireChecksGreen: asBoolean(args.requireChecksGreen) ?? true,
          webqaPass: asBoolean(args.webqaPass),
        });

        return policy;
      },
    },
    {
      definition: {
        name: "runner.start",
        description: "Start ephemeral hosted runner sandbox (stub in Stage 3 MVP).",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            ref: { type: "string" },
          },
          required: ["repo", "ref"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const repo = asString(args.repo);
        const ref = asString(args.ref);
        if (!repo || !ref) {
          throw new Error("missing_repo_or_ref");
        }
        return deps.runnerProvider.start({ repo, ref });
      },
    },
    {
      definition: {
        name: "runner.exec",
        description: "Execute command in hosted runner sandbox (stub in Stage 3 MVP).",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
            command: { type: "string" },
            timeoutSec: { type: "number" },
          },
          required: ["runId", "command"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const runId = asString(args.runId);
        const command = asString(args.command);
        const timeoutSec = asNumber(args.timeoutSec);
        if (!runId || !command) {
          throw new Error("missing_run_id_or_command");
        }
        return deps.runnerProvider.exec({ runId, command, timeoutSec });
      },
    },
    {
      definition: {
        name: "runner.applyPatch",
        description: "Apply patch in hosted runner sandbox (stub in Stage 3 MVP).",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
            unifiedDiff: { type: "string" },
          },
          required: ["runId", "unifiedDiff"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const runId = asString(args.runId);
        const unifiedDiff = asString(args.unifiedDiff);
        if (!runId || !unifiedDiff) {
          throw new Error("missing_run_id_or_diff");
        }
        return deps.runnerProvider.applyPatch({ runId, unifiedDiff });
      },
    },
    {
      definition: {
        name: "runner.commitAndPush",
        description: "Commit and push changes in hosted runner sandbox (stub in Stage 3 MVP).",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
            message: { type: "string" },
          },
          required: ["runId", "message"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const runId = asString(args.runId);
        const message = asString(args.message);
        if (!runId || !message) {
          throw new Error("missing_run_id_or_message");
        }
        return deps.runnerProvider.commitAndPush({ runId, message });
      },
    },
    {
      definition: {
        name: "runner.stop",
        description: "Stop hosted runner sandbox (stub in Stage 3 MVP).",
        input_schema: {
          type: "object",
          properties: {
            runId: { type: "string" },
          },
          required: ["runId"],
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (_context, args) => {
        const runId = asString(args.runId);
        if (!runId) {
          throw new Error("missing_run_id");
        }
        return deps.runnerProvider.stop({ runId });
      },
    },
    {
      definition: {
        name: "stage3.runTests",
        description: "Ensure PR exists for selected repo and summarize failing CI checks.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            baseRef: { type: "string" },
          },
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        emitStatus(context, `stage3.runTests for ${repo}`);

        let runRecord = await ensureRunRecord({
          context,
          github,
          repo,
          runStore: deps.runStore,
        });

        const baseRef = asString(args.baseRef) ?? runRecord.baseRef;
        const pr = await github.openOrUpdatePr({
          ref: parseRepoRef(repo),
          base: baseRef,
          head: runRecord.branch,
          title: `Abyss Stage 3 run ${runRecord.runId.slice(0, 8)}`,
          body: "Automated Stage 3 voice-run PR.\n\nThis PR is managed by Abyss tool server.",
          draft: true,
        });

        context.session.lastPrNumber = pr.number;
        context.session.lastPrUrl = pr.url;

        runRecord = updateRun(runRecord, {
          prNumber: pr.number,
          prUrl: pr.url,
          status: "running",
        });
        await deps.runStore.put(runRecord);

        const checks = await listChecksForPr(github, repo, pr.number);
        const summary = summarizeChecks(checks);
        emitArtifact(context, "CI Summary", summary.summary, {
          checks,
          prNumber: pr.number,
          prUrl: pr.url,
        });

        return {
          repo,
          runId: runRecord.runId,
          branch: runRecord.branch,
          prNumber: pr.number,
          prUrl: pr.url,
          checks,
          summary: summary.summary,
        };
      },
    },
    {
      definition: {
        name: "stage3.fixFailingTest",
        description: "Run the budgeted fix loop: diagnose failure, build context, generate/validate/apply patch, re-run checks.",
        input_schema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            prNumber: { type: "number" },
            maxIterations: { type: "number" },
            maxCiWaitMs: { type: "number" },
          },
        },
      },
      target: "server",
      sideEffect: "execute",
      execute: async (context, args) => {
        const github = requireGitHubClient(context.session);
        const repo = parseRepoFromArgs(context.session, args);
        let prNumber = asNumber(args.prNumber) ?? context.session.lastPrNumber;
        const maxIterations = Math.max(1, Math.min(asNumber(args.maxIterations) ?? 3, 6));
        const maxCiWaitMs = Math.max(30_000, Math.min(asNumber(args.maxCiWaitMs) ?? 180_000, 600_000));

        emitStatus(context, `stage3.fixFailingTest started for ${repo}`);

        let runRecord = await ensureRunRecord({
          context,
          github,
          repo,
          runStore: deps.runStore,
        });

        if (!prNumber) {
          const pr = await github.openOrUpdatePr({
            ref: parseRepoRef(repo),
            base: runRecord.baseRef,
            head: runRecord.branch,
            title: `Abyss Stage 3 fix ${runRecord.runId.slice(0, 8)}`,
            body: "Automated Stage 3 fix loop PR.",
            draft: true,
          });
          prNumber = pr.number;
          context.session.lastPrNumber = pr.number;
          context.session.lastPrUrl = pr.url;
          runRecord = updateRun(runRecord, {
            prNumber: pr.number,
            prUrl: pr.url,
          });
          await deps.runStore.put(runRecord);
        }

        if (!prNumber) {
          throw new Error("missing_pr_number");
        }

        let iteration = 0;
        let lastChecks = await listChecksForPr(github, repo, prNumber);

        while (iteration < maxIterations) {
          const summary = summarizeChecks(lastChecks);
          if (summary.pass) {
            runRecord = updateRun(runRecord, {
              status: "green",
              iteration,
            });
            await deps.runStore.put(runRecord);
            break;
          }

          iteration += 1;
          emitStatus(context, `Fix iteration ${iteration}/${maxIterations}`);

          const failing = summary.failingCheck;
          if (!failing) {
            break;
          }

          const checkLogs = await github.getCheckRun(parseRepoRef(repo), failing.id);
          const logsExcerpt = [checkLogs.outputTitle, checkLogs.outputSummary, checkLogs.outputText]
            .filter(Boolean)
            .join("\n")
            .slice(0, 12_000);

          const diagnosis = diagnoseCiFailure(logsExcerpt);
          runRecord = updateRun(runRecord, {
            status: "running",
            iteration,
            lastSignature: diagnosis.signature,
          });
          await deps.runStore.put(runRecord);

          emitArtifact(context, "Failure Diagnosis", `Detected ${diagnosis.classification} failure`, diagnosis as unknown as Record<string, unknown>);

          const prDiff = await github.listPrFiles(parseRepoRef(repo), prNumber);
          const bundle = await deps.contextEngine.buildBundle({
            github,
            repo,
            ref: runRecord.branch,
            goal: "Fix failing CI test and preserve behavior.",
            failureSignals: {
              ...diagnosis,
              logsExcerpt,
            },
            constraints: {
              allowedPaths: diagnosis.stackPaths?.map((path) => path.replace(/^\//, "")).slice(0, 12),
              noReformat: true,
              maxDiffLines: 250,
              mustFixSignature: diagnosis.signature,
            },
            budget: {
              maxChars: 45_000,
              topFullFiles: 4,
              topSnippets: 10,
            },
            currentPrDiff: prDiff,
          });

          let generated;
          try {
            generated = await deps.patchProvider.generateDiff({
              contextBundle: bundle,
              constraints: {
                allowedPaths: bundle.constraints.allowedPaths,
                maxDiffLines: bundle.constraints.maxDiffLines,
                noReformat: bundle.constraints.noReformat,
                mustFixSignature: bundle.constraints.mustFixSignature,
              },
            });
          } catch (error) {
            throw new Error(`patch_generate_failed:${error instanceof Error ? error.message : "unknown"}`);
          }

          const validation = validateUnifiedDiff(generated.unifiedDiff, {
            allowedPaths: bundle.constraints.allowedPaths,
            maxDiffLines: bundle.constraints.maxDiffLines,
            noReformat: bundle.constraints.noReformat,
            allowLockfiles: false,
          });

          if (!validation.ok) {
            emitArtifact(context, "Patch Rejected", "Validation blocked generated patch", {
              violations: validation.violations,
            });
            throw new Error(`patch_validation_failed:${validation.violations.join(",")}`);
          }

          const applyResult = await applyPatchToBranch({
            github,
            repo,
            branch: runRecord.branch,
            unifiedDiff: generated.unifiedDiff,
            commitMessage: `fix(stage3): ${diagnosis.signature}`,
          });

          emitArtifact(context, "Patch Commit", `Committed ${applyResult.changedFiles.length} files`, {
            commitSha: applyResult.commitSha,
            changedFiles: applyResult.changedFiles,
          });

          const checksAfterPatch = await waitForChecksTerminal(github, repo, prNumber, maxCiWaitMs);
          lastChecks = checksAfterPatch;
        }

        const finalSummary = summarizeChecks(lastChecks);
        if (!finalSummary.pass) {
          runRecord = updateRun(runRecord, {
            status: "blocked",
            iteration,
          });
          await deps.runStore.put(runRecord);

          return {
            ok: false,
            reason: "budget_exhausted_or_still_failing",
            iteration,
            checks: lastChecks,
            prNumber,
            prUrl: context.session.lastPrUrl,
          };
        }

        let previewUrl: string | undefined;
        let webqaRunId: string | undefined;
        let webqaPass: boolean | undefined;

        try {
          const preview = await findPreviewUrl({
            github,
            repo,
            prNumber,
            checks: lastChecks,
          });
          previewUrl = preview.url;
          emitArtifact(context, "Preview URL", previewUrl, preview);

          const webqaRun = await deps.webqaProvider.run(preview.url, {
            name: "smoke",
            steps: [
              { action: "navigate" },
            ],
          }, []);

          webqaRunId = webqaRun.runId;
          const artifacts = await deps.webqaProvider.artifacts(webqaRun.runId);
          webqaPass = artifacts.pass;
          emitArtifact(context, "Web QA", artifacts.pass ? "Web QA passed" : "Web QA failed", artifacts as unknown as Record<string, unknown>);
        } catch (error) {
          emitArtifact(context, "Preview/WebQA", "Preview or web validation unavailable", {
            error: error instanceof Error ? error.message : "unknown",
          });
        }

        runRecord = updateRun(runRecord, {
          status: "green",
          iteration,
          previewUrl,
          webqaPass,
        });
        await deps.runStore.put(runRecord);

        return {
          ok: true,
          iteration,
          checks: lastChecks,
          prNumber,
          prUrl: context.session.lastPrUrl,
          previewUrl,
          webqaRunId,
          webqaPass,
        };
      },
    },
  ];

  registry.registerMany([...clientTools, ...serverTools]);
  return registry;
}

export function buildModelToolset(registry: ToolRegistry): ToolDefinition[] {
  return registry.getDefinitions();
}

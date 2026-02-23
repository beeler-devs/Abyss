import { GitHubClient } from "../github/githubClient.js";
import { EmbeddingsIndexStore } from "../embeddings/indexStore.js";
import { parseRepoRef } from "../github/repo.js";

export interface FailureSignals {
  signature?: string;
  failingTests?: Array<{ name: string; file?: string; line?: number }>;
  stackPaths?: string[];
  keyErrors?: string[];
  suggestedQueries?: string[];
  logsExcerpt?: string;
}

export interface ContextConstraintSet {
  allowedPaths?: string[];
  noReformat?: boolean;
  maxDiffLines?: number;
  mustFixSignature?: string;
}

export interface ContextBudget {
  maxChars: number;
  topFullFiles: number;
  topSnippets: number;
}

export interface ContextBundle {
  goal: string;
  failureSummary: string;
  logsExcerpt: string;
  fullFiles: Array<{ path: string; content: string }>;
  snippets: Array<{ path: string; startLine: number; endLine: number; text: string }>;
  configs: Array<{ path: string; content: string }>;
  currentPrDiff?: Array<{ path: string; patch: string }>;
  constraints: ContextConstraintSet;
}

function normalizePath(path: string): string {
  return path.replace(/^\/+/, "");
}

function shouldIgnorePath(path: string): boolean {
  return /(^|\/)node_modules\//.test(path)
    || /(^|\/)dist\//.test(path)
    || /(^|\/)build\//.test(path)
    || /(^|\/)\.next\//.test(path)
    || /(^|\/)coverage\//.test(path);
}

function isLikelyTextFile(path: string): boolean {
  return /(\.ts|\.tsx|\.js|\.jsx|\.mjs|\.cjs|\.json|\.yml|\.yaml|\.md|\.go|\.py|\.java|\.swift|\.kt|\.rb|\.rs|\.sh|\.txt)$/.test(path);
}

function summarizeFailure(signals: FailureSignals): string {
  const tests = signals.failingTests?.map((test) => test.name).slice(0, 3).join(", ") ?? "unknown tests";
  const signature = signals.signature ?? "unknown-signature";
  return `Failure signature ${signature}. Failing tests: ${tests}.`;
}

export class ContextEngine {
  private readonly embeddings: EmbeddingsIndexStore;

  constructor(embeddings: EmbeddingsIndexStore) {
    this.embeddings = embeddings;
  }

  async buildBundle(args: {
    github: GitHubClient;
    repo: string;
    ref: string;
    goal: string;
    failureSignals: FailureSignals;
    constraints: ContextConstraintSet;
    budget: ContextBudget;
    currentPrDiff?: Array<{ path: string; patch: string }>;
  }): Promise<ContextBundle> {
    const { github, repo, ref, goal, failureSignals, constraints, budget, currentPrDiff } = args;
    const parsedRepo = parseRepoRef(repo);
    const tree = (await github.listTree(parsedRepo, ref))
      .filter((entry) => entry.type === "blob")
      .filter((entry) => !shouldIgnorePath(entry.path))
      .filter((entry) => isLikelyTextFile(entry.path));

    const selectedFullFiles: Array<{ path: string; content: string }> = [];
    const snippets: Array<{ path: string; startLine: number; endLine: number; text: string }> = [];
    const pathSet = new Set<string>();

    const stackPaths = failureSignals.stackPaths ?? [];
    for (const stackPath of stackPaths) {
      const normalized = normalizePath(stackPath);
      const matched = tree.find((entry) => entry.path.endsWith(normalized) || entry.path === normalized);
      if (!matched || pathSet.has(matched.path)) {
        continue;
      }

      const file = await github.getFile(parsedRepo, ref, matched.path);
      selectedFullFiles.push({ path: matched.path, content: file.content });
      pathSet.add(matched.path);
      if (selectedFullFiles.length >= budget.topFullFiles) {
        break;
      }
    }

    const queryTerms = failureSignals.suggestedQueries ?? [];
    for (const query of queryTerms) {
      if (selectedFullFiles.length >= budget.topFullFiles) {
        break;
      }
      const lexicalMatches = tree.filter((entry) => entry.path.includes(query)).slice(0, 2);
      for (const match of lexicalMatches) {
        if (pathSet.has(match.path)) {
          continue;
        }
        const file = await github.getFile(parsedRepo, ref, match.path);
        selectedFullFiles.push({ path: match.path, content: file.content });
        pathSet.add(match.path);
        if (selectedFullFiles.length >= budget.topFullFiles) {
          break;
        }
      }
    }

    if ((failureSignals.suggestedQueries ?? []).length > 0) {
      const embeddingQuery = (failureSignals.suggestedQueries ?? []).join("\n");
      const embedded = await this.embeddings.query(repo, ref, embeddingQuery, budget.topSnippets);
      for (const chunk of embedded) {
        snippets.push({
          path: chunk.path,
          startLine: chunk.startLine,
          endLine: chunk.endLine,
          text: chunk.text,
        });
        if (snippets.length >= budget.topSnippets) {
          break;
        }
      }
    }

    const configPaths = tree
      .filter((entry) => /(^|\/)(package\.json|pnpm-workspace\.yaml|jest\.config|vitest\.config|playwright\.config|tsconfig\.json)$/i.test(entry.path))
      .slice(0, 6);

    const configs: Array<{ path: string; content: string }> = [];
    for (const configPath of configPaths) {
      const file = await github.getFile(parsedRepo, ref, configPath.path);
      configs.push({ path: configPath.path, content: file.content.slice(0, 6000) });
    }

    let charsUsed = 0;
    const fullFilesBudgeted: Array<{ path: string; content: string }> = [];
    for (const file of selectedFullFiles) {
      if (charsUsed >= budget.maxChars) {
        break;
      }
      const remaining = budget.maxChars - charsUsed;
      fullFilesBudgeted.push({
        path: file.path,
        content: file.content.slice(0, remaining),
      });
      charsUsed += Math.min(file.content.length, remaining);
    }

    const snippetsBudgeted: Array<{ path: string; startLine: number; endLine: number; text: string }> = [];
    for (const snippet of snippets) {
      if (charsUsed >= budget.maxChars) {
        break;
      }
      const remaining = budget.maxChars - charsUsed;
      const text = snippet.text.slice(0, remaining);
      snippetsBudgeted.push({ ...snippet, text });
      charsUsed += text.length;
    }

    return {
      goal,
      failureSummary: summarizeFailure(failureSignals),
      logsExcerpt: (failureSignals.logsExcerpt ?? "").slice(0, 8000),
      fullFiles: fullFilesBudgeted,
      snippets: snippetsBudgeted,
      configs,
      currentPrDiff,
      constraints,
    };
  }
}

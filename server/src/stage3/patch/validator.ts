import { diffChangedLineCount, parseUnifiedDiff, whitespaceOnlyChangeCount } from "./unifiedDiff.js";

export interface PatchConstraints {
  allowedPaths?: string[];
  noReformat?: boolean;
  maxDiffLines?: number;
  allowLockfiles?: boolean;
}

export interface PatchValidationResult {
  ok: boolean;
  violations: string[];
  changedFiles: string[];
  diffLineCount: number;
}

function isLockfile(path: string): boolean {
  return /(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|composer\.lock)$/i.test(path);
}

function pathAllowed(path: string, allowedPaths?: string[]): boolean {
  if (!allowedPaths || allowedPaths.length === 0) {
    return true;
  }
  return allowedPaths.some((allowed) => path.startsWith(allowed));
}

export function validateUnifiedDiff(unifiedDiff: string, constraints: PatchConstraints): PatchValidationResult {
  const violations: string[] = [];

  let parsed;
  try {
    parsed = parseUnifiedDiff(unifiedDiff);
  } catch (error) {
    const message = error instanceof Error ? error.message : "invalid_diff";
    return {
      ok: false,
      violations: [`invalid_diff:${message}`],
      changedFiles: [],
      diffLineCount: 0,
    };
  }

  const changedFiles = parsed.map((file) => file.newPath || file.oldPath).filter(Boolean);

  for (const path of changedFiles) {
    if (!pathAllowed(path, constraints.allowedPaths)) {
      violations.push(`path_not_allowed:${path}`);
    }
    if (!constraints.allowLockfiles && isLockfile(path)) {
      violations.push(`lockfile_change_forbidden:${path}`);
    }
  }

  const diffLineCount = diffChangedLineCount(parsed);
  if (constraints.maxDiffLines && diffLineCount > constraints.maxDiffLines) {
    violations.push(`diff_too_large:${diffLineCount}>${constraints.maxDiffLines}`);
  }

  if (constraints.noReformat) {
    const whitespaceOnly = whitespaceOnlyChangeCount(parsed);
    if (diffLineCount > 0 && whitespaceOnly / diffLineCount > 0.6) {
      violations.push("excessive_whitespace_only_changes");
    }
  }

  return {
    ok: violations.length === 0,
    violations,
    changedFiles,
    diffLineCount,
  };
}

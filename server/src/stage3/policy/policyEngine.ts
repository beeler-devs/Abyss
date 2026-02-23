export interface MergePolicyResult {
  allowed: boolean;
  blockers: string[];
}

export interface MergePolicyInput {
  checks: Array<{ name: string; status: string; conclusion: string | null }>;
  approvals?: number;
  requireWebQA: boolean;
  webqaPass?: boolean;
  requireChecksGreen: boolean;
}

export function checkMergePolicy(input: MergePolicyInput): MergePolicyResult {
  const blockers: string[] = [];

  if (input.requireChecksGreen) {
    const failingChecks = input.checks.filter((check) => {
      if (check.status !== "completed") {
        return true;
      }
      return check.conclusion !== "success" && check.conclusion !== "neutral";
    });

    if (failingChecks.length > 0) {
      blockers.push(`failing_checks:${failingChecks.map((check) => check.name).join(",")}`);
    }
  }

  if (input.requireWebQA && !input.webqaPass) {
    blockers.push("webqa_not_passing");
  }

  if (typeof input.approvals === "number" && input.approvals < 1) {
    blockers.push("missing_approvals");
  }

  return {
    allowed: blockers.length === 0,
    blockers,
  };
}

import crypto from "node:crypto";

export type FailureClassification =
  | "compile"
  | "test"
  | "lint"
  | "typecheck"
  | "e2e"
  | "flaky"
  | "infra";

export interface FailureDiagnosis {
  classification: FailureClassification;
  signature: string;
  failingTests: Array<{ name: string; file?: string; line?: number }>;
  stackPaths: string[];
  keyErrors: string[];
  suggestedQueries: string[];
}

const PATH_PATTERN = /((?:[A-Za-z]:)?[\w./-]+\.(?:ts|tsx|js|jsx|go|py|rb|java|swift|kt|rs|c|cpp|cs))(?:[:(](\d+))?/g;

function classify(text: string): FailureClassification {
  const lower = text.toLowerCase();
  if (/(cannot find module|compilation failed|syntaxerror|build failed)/.test(lower)) {
    return "compile";
  }
  if (/(ts\d{4}|type error|typecheck|cannot assign)/.test(lower)) {
    return "typecheck";
  }
  if (/(eslint|prettier|lint)/.test(lower)) {
    return "lint";
  }
  if (/(playwright|cypress|selenium|e2e)/.test(lower)) {
    return "e2e";
  }
  if (/(network timeout|service unavailable|runner lost|cancelled by infrastructure|no space left on device)/.test(lower)) {
    return "infra";
  }
  if (/(flaky|timed out occasionally|retry passed|intermittent)/.test(lower)) {
    return "flaky";
  }
  return "test";
}

function extractFailingTests(text: string): Array<{ name: string; file?: string; line?: number }> {
  const failingTests: Array<{ name: string; file?: string; line?: number }> = [];
  const lines = text.split(/\r?\n/);

  for (const line of lines) {
    const jestMatch = line.match(/^\s*●\s+(.*)$/);
    if (jestMatch?.[1]) {
      failingTests.push({ name: jestMatch[1].trim() });
      continue;
    }

    const vitestMatch = line.match(/^\s*FAIL\s+(.+?)\s*>\s*(.+)$/);
    if (vitestMatch) {
      failingTests.push({
        name: vitestMatch[2].trim(),
        file: vitestMatch[1].trim(),
      });
      continue;
    }

    const goMatch = line.match(/^--- FAIL: (.+?) \(/);
    if (goMatch?.[1]) {
      failingTests.push({ name: goMatch[1].trim() });
    }
  }

  return failingTests.slice(0, 20);
}

function extractStackPaths(text: string): string[] {
  const paths = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = PATH_PATTERN.exec(text)) !== null) {
    const file = match[1];
    if (!file) {
      continue;
    }
    paths.add(file);
  }
  return [...paths].slice(0, 30);
}

function extractKeyErrors(text: string): string[] {
  const lines = text
    .split(/\r?\n/)
    .filter((line) => /(error|exception|assertion|expected|received|panic|failed)/i.test(line))
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  return [...new Set(lines)].slice(0, 15);
}

function buildSignature(classification: FailureClassification, failingTests: Array<{ name: string }>, keyErrors: string[]): string {
  const signatureInput = [
    classification,
    ...failingTests.map((test) => test.name),
    ...keyErrors,
  ].join("|");

  const hash = crypto.createHash("sha1").update(signatureInput).digest("hex");
  return `${classification}:${hash.slice(0, 16)}`;
}

function buildQueries(
  failingTests: Array<{ name: string; file?: string }>,
  keyErrors: string[],
  stackPaths: string[],
): string[] {
  const queries = new Set<string>();

  for (const test of failingTests) {
    queries.add(test.name);
    if (test.file) {
      queries.add(test.file);
    }
  }

  for (const keyError of keyErrors.slice(0, 6)) {
    queries.add(keyError.replace(/\s+/g, " ").slice(0, 120));
  }

  for (const path of stackPaths.slice(0, 8)) {
    queries.add(path);
  }

  return [...queries].slice(0, 20);
}

export function diagnoseCiFailure(logsExcerpt: string): FailureDiagnosis {
  const text = logsExcerpt.trim();
  const classification = classify(text);
  const failingTests = extractFailingTests(text);
  const stackPaths = extractStackPaths(text);
  const keyErrors = extractKeyErrors(text);
  const signature = buildSignature(classification, failingTests, keyErrors);
  const suggestedQueries = buildQueries(failingTests, keyErrors, stackPaths);

  return {
    classification,
    signature,
    failingTests,
    stackPaths,
    keyErrors,
    suggestedQueries,
  };
}

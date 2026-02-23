import test from "node:test";
import assert from "node:assert/strict";

import { diagnoseCiFailure } from "../src/stage3/ci/diagnose.js";

test("diagnose.ciFailure extracts signature and failing tests", () => {
  const logs = [
    "FAIL src/math/sum.test.ts > sum > handles positive numbers",
    "AssertionError: expected 5 but received 1",
    "at src/math/sum.ts:14:10",
    "at src/math/sum.test.ts:9:3",
  ].join("\n");

  const diagnosis = diagnoseCiFailure(logs);

  assert.equal(diagnosis.classification, "test");
  assert.ok(diagnosis.signature.startsWith("test:"));
  assert.ok(diagnosis.failingTests.length > 0);
  assert.ok(diagnosis.stackPaths.some((path) => path.includes("src/math/sum.ts")));
  assert.ok(diagnosis.keyErrors.some((line) => line.includes("AssertionError")));
  assert.ok(diagnosis.suggestedQueries.length > 0);
});

test("diagnose.ciFailure classifies lint failures", () => {
  const logs = "ESLint: Unexpected console statement in src/index.ts";
  const diagnosis = diagnoseCiFailure(logs);

  assert.equal(diagnosis.classification, "lint");
});

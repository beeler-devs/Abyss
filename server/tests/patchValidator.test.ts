import test from "node:test";
import assert from "node:assert/strict";

import { validateUnifiedDiff } from "../src/stage3/patch/validator.js";

test("patch validator rejects disallowed paths and lockfiles", () => {
  const diff = [
    "--- a/src/app.ts",
    "+++ b/src/app.ts",
    "@@ -1,1 +1,1 @@",
    "-const a = 1;",
    "+const a = 2;",
    "--- a/package-lock.json",
    "+++ b/package-lock.json",
    "@@ -1,1 +1,1 @@",
    "-{}",
    "+{\"lock\":true}",
  ].join("\n");

  const result = validateUnifiedDiff(diff, {
    allowedPaths: ["src/"],
    noReformat: true,
    maxDiffLines: 20,
    allowLockfiles: false,
  });

  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.includes("path_not_allowed:package-lock.json")));
  assert.ok(result.violations.some((v) => v.includes("lockfile_change_forbidden:package-lock.json")));
});

test("patch validator accepts focused patch", () => {
  const diff = [
    "--- a/src/util.ts",
    "+++ b/src/util.ts",
    "@@ -2,3 +2,4 @@",
    " export function sum(a: number, b: number): number {",
    "-  return a - b;",
    "+  // Fix subtraction bug causing test failure.",
    "+  return a + b;",
    " }",
  ].join("\n");

  const result = validateUnifiedDiff(diff, {
    allowedPaths: ["src/"],
    noReformat: true,
    maxDiffLines: 30,
    allowLockfiles: false,
  });

  assert.equal(result.ok, true);
  assert.equal(result.violations.length, 0);
  assert.equal(result.changedFiles[0], "src/util.ts");
});

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const drift = parse(
  await readFile(
    path.join(repositoryRoot, ".github/workflows/drift.yaml"),
    "utf8",
  ),
);

test("drift and synthetic health use distinct off-hour schedules", () => {
  assert.deepEqual(
    drift.on.schedule.map(({ cron }) => cron),
    ["17 5 * * *", "43 */3 * * *"],
  );
  assert.match(drift.jobs.inspect.if, /github\.event\.schedule == '17 5/);
  assert.match(drift.jobs.health.if, /github\.event\.schedule == '43 \*\/3/);
  assert.match(
    drift.jobs.health.if,
    /vars\.PRODUCTION_RELEASES_ENABLED == 'true'/,
  );
});

test("synthetic health remains inside the read-only plan trust boundary", () => {
  const health = drift.jobs.health;

  assert.deepEqual(drift.permissions, {});
  assert.deepEqual(health.permissions, {
    contents: "read",
    "id-token": "write",
  });
  assert.equal(health.environment, undefined);
  assert.equal(health["timeout-minutes"], 10);
  assert.ok(
    health.steps.some(
      (step) =>
        step.uses ===
        "google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093",
    ),
  );
});

test("synthetic health reads private foundation coordinates without logging a response", () => {
  const check = drift.jobs.health.steps.find(
    (step) => step.name === "Check Authentication and its dependencies",
  );

  assert.deepEqual(check.env, {
    STATE_BUCKET: "${{ vars.GCP_STATE_BUCKET }}",
  });
  assert.match(check.run, /config-custody\.sh fetch/);
  assert.match(check.run, /check-authentication-health\.sh/);
  assert.doesNotMatch(check.run, /\b(cat|tee)\b|set -x/);
});

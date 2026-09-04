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
const release = parse(
  await readFile(
    path.join(repositoryRoot, ".github/workflows/release.yaml"),
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

test("first-launch recovery is explicit and narrowly privileged", () => {
  const action = release.on.workflow_dispatch.inputs.action;
  const failedRunId = release.on.workflow_dispatch.inputs.failed_run_id;
  const job = release.jobs.release;

  assert.deepEqual(action.options, [
    "deploy",
    "rollback",
    "recover-first-launch",
  ]);
  assert.equal(failedRunId.required, false);
  assert.deepEqual(job.permissions, {
    actions: "read",
    attestations: "read",
    contents: "read",
    "id-token": "write",
    "pull-requests": "read",
  });

  const verify = job.steps.find(
    (step) => step.name === "Verify the failed first-launch run",
  );
  assert.equal(verify.if, "env.RELEASE_ACTION == 'recover-first-launch'");
  assert.match(verify.run, /actions\/runs\/\$\{FAILED_RUN_ID\}/);
  assert.match(verify.run, /\.conclusion == "failure"/);
  assert.match(verify.run, /production deploy by @/);

  const recover = job.steps.find(
    (step) => step.name === "Recover the interrupted first launch",
  );
  assert.equal(recover.if, "env.RELEASE_ACTION == 'recover-first-launch'");
  assert.match(recover.run, /\.\/ops\/recover-first-launch\.sh/);
  assert.doesNotMatch(recover.run, /all-instances-config|update-instances/);
});

test("first-launch recovery skips unrelated release tooling", () => {
  const job = release.jobs.release;
  for (const name of [
    "Install OpenTofu",
    "Authenticate Docker to the regional registry",
    "Select the receipt-owned prior state",
    "Compile exact candidate, active, and compensation inputs",
  ]) {
    const step = job.steps.find((candidate) => candidate.name === name);
    assert.equal(step.if, "env.RELEASE_ACTION != 'recover-first-launch'");
  }
});

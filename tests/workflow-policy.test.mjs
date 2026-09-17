import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const main = parse(
  await readFile(
    path.join(repositoryRoot, ".github/workflows/main.yaml"),
    "utf8",
  ),
);
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

test("operational jobs build reviewed Go tooling before protected inputs or credentials", async () => {
  const foundation = parse(
    await readFile(
      path.join(repositoryRoot, ".github/workflows/foundation.yaml"),
      "utf8",
    ),
  );
  const recovery = parse(
    await readFile(
      path.join(repositoryRoot, ".github/workflows/recovery.yaml"),
      "utf8",
    ),
  );
  for (const job of [
    release.jobs.release,
    release.jobs["database-isolation"],
    recovery.jobs.recover,
    drift.jobs.health,
    drift.jobs.inspect,
    drift.jobs["assess-resource-deletion"],
    foundation.jobs.execute,
  ]) {
    const build = job.steps.findIndex(
      (step) => step.uses === "$/.github/actions/setup-infra",
    );
    const protectedInput = job.steps.findIndex((step) =>
      /secrets\.|google-github-actions\/auth/.test(JSON.stringify(step)),
    );
    assert.ok(build >= 0 && build < protectedInput);
    assert.doesNotMatch(JSON.stringify(job), /setup-node|pnpm|go run|go build/);
  }
  const build = parse(
    await readFile(
      path.join(repositoryRoot, ".github/actions/setup-infra/action.yaml"),
      "utf8",
    ),
  );
  assert.equal(build.runs.steps[0].with.cache, false);
  assert.match(build.runs.steps[1].run, /go build -mod=readonly/);
  assert.doesNotMatch(JSON.stringify(build), /secrets\.|vars\.|cache: true/);
  assert.ok(
    main.jobs["lint-repository"].steps.some(
      (step) => step.uses === "$/.github/actions/setup-infra",
    ),
  );
  assert.doesNotMatch(
    JSON.stringify(main.jobs["validate-opentofu"]),
    /pnpm|setup-node/,
  );
});

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
    health.steps.some((step) =>
      /^google-github-actions\/auth@v[0-9]+\.[0-9]+\.[0-9]+$/.test(step.uses),
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
  assert.match(check.run, /infra custody config fetch/);
  assert.match(check.run, /infra check-health deployed/);
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
    "drill-database-isolation",
    "restore-database-isolation",
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
  assert.match(recover.run, /infra database-release recover-first-launch/);
  assert.doesNotMatch(recover.run, /all-instances-config|update-instances/);
});

test("first-launch recovery skips unrelated release tooling", () => {
  const job = release.jobs.release;
  for (const name of [
    "Install OpenTofu",
    "Authenticate Docker to the regional registry",
    "Select the receipt-owned prior state",
    "Resolve the exact manifest for a legacy receipt",
    "Validate the deployed family transition and compile exact inputs",
  ]) {
    const step = job.steps.find((candidate) => candidate.name === name);
    assert.equal(step.if, "env.RELEASE_ACTION != 'recover-first-launch'");
  }
});

test("deployment checks the receipt-owned transition before any runtime mutation", () => {
  const steps = release.jobs.release.steps;
  const compile = steps.findIndex(
    (step) =>
      step.name ===
      "Validate the deployed family transition and compile exact inputs",
  );
  const deploy = steps.findIndex(
    (step) => step.name === "Deploy the selected service scope",
  );
  assert.ok(compile >= 0 && compile < deploy);
  assert.match(steps[compile].run, /infra compile-release/);
  assert.equal(
    steps[compile].env.PRIOR_RECEIPT,
    "${{ steps.prior.outputs.argument }}",
  );
  assert.match(steps[deploy].run, /release\.json/);
  assert.equal(release.concurrency.group, "production-infrastructure");
  assert.equal(release.concurrency["cancel-in-progress"], false);
});

test("resource-deletion approval is a merge-queue-aware required check", () => {
  const gate = main.jobs["resource-deletion-gate"];

  assert.equal(main.on.merge_group, null);
  assert.deepEqual(gate.permissions, {
    actions: "read",
    contents: "read",
    "pull-requests": "read",
  });
  assert.equal(gate.environment, undefined);
  assert.equal(gate.permissions["id-token"], undefined);
  assert.deepEqual(
    new Set(main.on.pull_request.types),
    new Set(["opened", "reopened", "synchronize", "labeled", "unlabeled"]),
  );

  const checkout = gate.steps.find(
    (step) => step.name === "Check out trusted gate tooling",
  );
  assert.match(checkout.with.ref, /pull_request\.base\.sha/);
  assert.match(checkout.with.ref, /merge_group\.base_sha/);
  assert.equal(checkout.with["persist-credentials"], false);

  const verify = gate.steps.find(
    (step) => step.name === "Verify exact assessment and current approval",
  );
  assert.match(verify.run, /verify-resource-deletion-gate\.sh/);
  assert.doesNotMatch(
    JSON.stringify(gate),
    /secrets\.|google-github-actions\/auth/,
  );
});

test("trusted assessment authorizes the candidate before cloud credentials exist", () => {
  const assessment = drift.jobs["assess-resource-deletion"];

  assert.deepEqual(assessment.permissions, {
    actions: "read",
    contents: "read",
    "id-token": "write",
    "pull-requests": "read",
  });
  assert.equal(assessment.environment, undefined);
  assert.match(assessment.if, /inputs\.operation == 'assess-pull-request'/);

  const names = assessment.steps.map((step) => step.name);
  const authorize = names.indexOf(
    "Resolve maintainer-approved exact candidate",
  );
  const authenticate = names.indexOf(
    "Authenticate as the read-only plan boundary",
  );
  assert.ok(authorize >= 0 && authorize < authenticate);
  const candidate = assessment.steps.find(
    (step) => step.name === "Check out the exact candidate without running it",
  );
  assert.equal(candidate.with.ref, "${{ inputs.head_sha }}");
  assert.equal(
    candidate.with.repository,
    "${{ steps.target.outputs.repository }}",
  );

  const publish = assessment.steps.find(
    (step) => step.name === "Publish the payload-free verdict",
  );
  assert.match(publish.with.path, /assessment\.json$/);
  assert.doesNotMatch(publish.with.path, /tfplan|tfvars|state/);
});

test("trusted assessment authenticates each GitHub metadata step", () => {
  const assessment = drift.jobs["assess-resource-deletion"];

  for (const name of [
    "Resolve maintainer-approved exact candidate",
    "Assess plans with current private inputs",
  ]) {
    const step = assessment.steps.find((candidate) => candidate.name === name);
    assert.equal(step.env.GH_TOKEN, "${{ github.token }}", name);
  }
});

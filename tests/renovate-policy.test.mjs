import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { parse } from "yaml";

const read = (file) => readFile(new URL(`../${file}`, import.meta.url), "utf8");
const config = JSON.parse(await read("renovate.json"));

test("Renovate declares a four-image minimum for each service family", () => {
  for (const service of ["service-json-keys", "service-authentication"]) {
    const rules = config.packageRules.filter(
      (rule) => rule.groupName === `${service} images`,
    );
    assert.equal(rules.length, 1);
    const { description, ...rule } = rules[0];
    assert.deepEqual(rule, {
      matchDatasources: ["docker"],
      matchFileNames: ["deploy/production/images.yaml"],
      matchPackageNames: [`ghcr.io/a-novel/${service}/**`],
      groupName: `${service} images`,
      minimumGroupSize: 4,
      groupSlug: `${service}-images`,
      separateMajorMinor: true,
    });
  }
});

test("Renovate runs on a schedule or manual dispatch with no cloud authority", async () => {
  const workflow = parse(await read(".github/workflows/renovate.yaml"));
  assert.deepEqual(
    new Set(Object.keys(workflow.on)),
    new Set(["schedule", "workflow_dispatch"]),
  );
  assert.ok(workflow.on.schedule.length > 0);
  assert.deepEqual(workflow.permissions, {});
  const job = workflow.jobs.renovate;
  assert.equal(job.if, "github.ref == 'refs/heads/master'");
  assert.deepEqual(job.permissions, { contents: "read", packages: "read" });
  assert.equal(job.environment, undefined);
  const runner = job.steps.find((step) =>
    step.uses?.startsWith("a-novel-kit/workflows/generic-actions/renovate@"),
  );
  assert.ok(runner);
  assert.deepEqual(runner.with, {
    github_token: "${{ github.token }}",
    app_private_key: "${{ secrets.DEPENDENCY_BOT_PRIVATE_KEY }}",
    client_id: "${{ vars.DEPENDENCY_BOT_CLIENT_ID }}",
  });
});

test("Renovate reserves manual review for production, HCL, and OpenTofu", () => {
  const reviewRules = config.packageRules.filter(
    (rule) => rule.automerge !== undefined,
  );
  assert.equal(config.automerge, undefined);
  assert.deepEqual(
    reviewRules.map((rule) =>
      Object.fromEntries(
        Object.entries(rule).filter(
          ([key]) => key.startsWith("match") || key === "automerge",
        ),
      ),
    ),
    [
      {
        matchDatasources: ["docker"],
        matchFileNames: ["deploy/production/images.yaml"],
        automerge: false,
      },
      { matchPackageNames: ["opentofu/opentofu"], automerge: false },
      {
        matchFileNames: [
          "bootstrap/**",
          "environments/production/**",
          "deploy/production/**",
          "**/*.tf",
          "**/*.tf.json",
          "**/*.tofu",
          "**/*.tofu.json",
          "**/.terraform.lock.hcl",
        ],
        automerge: false,
      },
    ],
  );
  assert.equal(config.packageRules.at(-1), reviewRules.at(-1));
});

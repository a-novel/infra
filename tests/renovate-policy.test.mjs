import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { init } from "renovate/dist/logger/index.js";
import { extractPackageFile } from "renovate/dist/modules/manager/custom/regex/index.js";
import { applyPackageRules } from "renovate/dist/util/package-rules/index.js";
import { parse } from "yaml";

await init();
const read = (file) => readFile(new URL(`../${file}`, import.meta.url), "utf8");
const config = JSON.parse(await read("renovate.json"));

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

test("Renovate extracts each annotated tool version from the actual CI workflow", async () => {
  const file = ".github/workflows/main.yaml";
  const content = await read(file);
  const dependencies = config.customManagers.flatMap((manager) => {
    if (
      !manager.managerFilePatterns.some((pattern) =>
        new RegExp(pattern.slice(1, -1)).test(file),
      )
    )
      return [];
    return extractPackageFile(content, file, manager)?.deps ?? [];
  });
  for (const [, datasource, depName, currentValue] of content.matchAll(
    /# renovate: datasource=(\S+) depName=(\S+)\s+\w+:\s*["']?(v?\d+\.\d+\.\d+)/g,
  )) {
    assert.ok(
      dependencies.some(
        (dependency) =>
          dependency.datasource === datasource &&
          dependency.depName === depName &&
          dependency.currentValue === currentValue,
      ),
      depName,
    );
  }
  assert.ok(
    dependencies.some(
      (dependency) => dependency.depName === "terraform-linters/tflint",
    ),
  );
});

test("Renovate preserves review-only updates over inherited automerge rules", async () => {
  for (const updateType of [
    "major",
    "minor",
    "patch",
    "pin",
    "digest",
    "lockFileMaintenance",
  ]) {
    const result = await applyPackageRules({
      manager: "npm",
      packageName:
        updateType === "lockFileMaintenance" ? undefined : "future-dependency",
      updateType,
      packageRules: [
        { matchUpdateTypes: [updateType], automerge: true },
        ...config.packageRules,
      ],
    });
    assert.equal(result.automerge, false, updateType);
  }
});

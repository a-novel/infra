import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const privateValue = "fixture-private-plan-value";
const deletionRule = (age) => [
  { action: [{ type: "Delete" }], condition: [{ age }] },
];
const disk = (auto_delete) => [
  { device_name: "data", source: "data", mode: "READ_WRITE", auto_delete },
];

async function fixture(t, resource = {}, extra = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "infra-plan-policy-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, "plan.json");
  await writeFile(
    file,
    JSON.stringify({
      format_version: "1.2",
      terraform_version: "1.12.6",
      errored: false,
      resource_changes: [
        {
          mode: "managed",
          type: "future_resource",
          address: privateValue,
          change: { actions: ["update"], before: {}, after: {} },
          ...resource,
        },
      ],
      ...extra,
    }),
  );
  return { directory, file };
}

function run(args, env = {}) {
  return spawnSync("bash", args, {
    cwd: root,
    encoding: "utf8",
    timeout: 10000,
    env: { ...process.env, ...env },
  });
}

const cases = {
  google_storage_bucket: {
    "retention_policy.0.retention_period": [604800, 86400],
    retention_policy: [[{ retention_period: 604800 }], []],
    "retention_policy.0.is_locked": [true, false],
    "versioning.0.enabled": [true, false],
    "soft_delete_policy.0.retention_duration_seconds": [604800, 0],
    lifecycle_rule: [deletionRule(14), deletionRule(1)],
    public_access_prevention: ["enforced", "inherited"],
    uniform_bucket_level_access: [true, false],
  },
  google_secret_manager_secret: { version_destroy_ttl: ["2592000s", "0s"] },
  google_compute_instance_template: { disk: [disk(false), disk(true)] },
  google_compute_instance_group_manager: {
    stateful_disk: [[{ device_name: "data", delete_rule: "NEVER" }], []],
  },
  google_compute_resource_policy: {
    "snapshot_schedule_policy.0.retention_policy.0.max_retention_days": [7, 1],
  },
  google_cloud_scheduler_job: {
    paused: [false, true],
    schedule: ["0 */4 * * *", "0 0 * * *"],
    time_zone: ["UTC", "Europe/Paris"],
  },
  future_resource: {
    deletion_protection: [true, false],
    force_destroy: [false, true],
    deletion_policy: ["PREVENT", "DELETE"],
  },
};

function fieldValue(field, value) {
  return field
    .split(".")
    .reverse()
    .reduce((child, key) => (key === "0" ? [child] : { [key]: child }), value);
}

for (const [type, fields] of Object.entries(cases)) {
  for (const [field, [before, after]] of Object.entries(fields)) {
    test(`plan policy rejects weakened ${type}.${field}`, async (t) => {
      for (const [value, code] of [
        [before, 0],
        [after, 65],
      ]) {
        const { file } = await fixture(t, {
          type,
          change: {
            actions: ["update"],
            before: fieldValue(field, before),
            after: fieldValue(field, value),
          },
        });
        const result = run(["ops/plan-summary.sh", "foundation", file]);
        assert.equal(result.status, code, result.stderr);
        assert.doesNotMatch(
          result.stdout + result.stderr,
          new RegExp(privateValue),
        );
      }
    });
  }
}

for (const status of ["fail", "error", "unknown", "unsupported", null]) {
  test(`plan policy blocks ${status} check assertions`, async (t) => {
    const { file } = await fixture(
      t,
      {},
      {
        checks: [
          {
            status,
            instances: [{ status, problems: [{ message: privateValue }] }],
          },
        ],
      },
    );
    const result = run(["ops/plan-summary.sh", "foundation", file]);
    assert.equal(result.status, 65);
    assert.doesNotMatch(
      result.stdout + result.stderr,
      new RegExp(privateValue),
    );
  });
}

for (const extra of [
  { errored: true },
  { format_version: "2.0" },
  { checks: false },
  { checks: [{ status: "pass", instances: false }] },
  { checks: [{ status: "pass", instances: [{ status: "fail" }] }] },
]) {
  test(`malformed or failed plan cannot pass: ${JSON.stringify(extra)}`, async (t) => {
    const { file } = await fixture(t, {}, extra);
    assert.equal(run(["ops/plan-summary.sh", "foundation", file]).status, 65);
  });
}

test("adding a cleanup rule requires policy review", async (t) => {
  const { file } = await fixture(t, {
    type: "google_storage_bucket",
    change: {
      actions: ["update"],
      before: {},
      after: { lifecycle_rule: deletionRule(1) },
    },
  });
  assert.equal(run(["ops/plan-summary.sh", "bootstrap", file]).status, 65);
});

test("missing updated resource values cannot bypass protection checks", async (t) => {
  const { file } = await fixture(t, {
    change: {
      actions: ["update"],
      before: { deletion_protection: true },
      after: null,
    },
  });
  assert.equal(run(["ops/plan-summary.sh", "foundation", file]).status, 65);
});

for (const after_unknown of [
  true,
  { retention_policy: true },
  { retention_policy: [{ retention_period: true }] },
]) {
  test(`plan policy rejects unknown protected values ${JSON.stringify(after_unknown)}`, async (t) => {
    const value = { retention_policy: [{ retention_period: 604800 }] };
    const { file } = await fixture(t, {
      type: "google_storage_bucket",
      change: {
        actions: ["update"],
        before: value,
        after: value,
        after_unknown,
      },
    });
    assert.equal(run(["ops/plan-summary.sh", "bootstrap", file]).status, 65);
  });
}

test("safe updates and stronger retention pass with unrelated unknown values", async (t) => {
  const { file } = await fixture(
    t,
    {
      type: "google_storage_bucket",
      change: {
        actions: ["update"],
        before: {
          retention_policy: [{ retention_period: 604800 }],
          labels: { version: "old" },
        },
        after: {
          retention_policy: [{ retention_period: 1209600 }],
          labels: { version: "new" },
        },
        after_unknown: { id: true },
      },
    },
    { checks: [{ status: "pass", instances: [{ status: "pass" }] }] },
  );
  assert.equal(run(["ops/plan-summary.sh", "bootstrap", file]).status, 0);
});

test("preserved disks permit unrelated computed fields and disk reordering", async (t) => {
  const boot = { device_name: "boot", auto_delete: true };
  const { file } = await fixture(t, {
    type: "google_compute_instance_template",
    change: {
      actions: ["update"],
      before: { disk: [boot, ...disk(false)] },
      after: { disk: [...disk(false), boot] },
      after_unknown: { disk: [{ disk_size_gb: true }, { source_image: true }] },
    },
  });
  const result = run(["ops/plan-summary.sh", "foundation", file]);
  assert.equal(result.status, 0, result.stderr);
});

for (const actions of [
  ["delete"],
  ["delete", "create"],
  ["create", "delete"],
  ["forget"],
]) {
  test(`future resource ${actions.join("/")} still requires deletion approval`, async (t) => {
    const { file } = await fixture(t, {
      change: {
        actions,
        before: {},
        after: actions.includes("create") ? {} : null,
      },
    });
    assert.equal(run(["ops/plan-summary.sh", "foundation", file]).status, 3);
  });
}

for (const action of ["plan", "assess", "apply", "converge", "drift"]) {
  test(`${action} rejects unsafe settings even with deletion approval`, async (t) => {
    const { directory, file } = await fixture(t, {
      change: {
        actions: ["update"],
        before: { deletion_protection: true },
        after: { deletion_protection: false },
      },
    });
    await symlink(
      path.join(root, "tests/fixtures/fake-tofu.sh"),
      path.join(directory, "tofu"),
    );
    await symlink("/usr/bin/true", path.join(directory, "git"));
    const env = {
      PATH: `${directory}:${process.env.PATH}`,
      FAKE_TOFU_PLAN_JSON: file,
      FAKE_TOFU_PLAN_CODE: "2",
      FAKE_TOFU_FAIL_ACTION: "apply",
      ALLOW_RESOURCE_DELETION: "true",
    };
    const savedPlan = path.join(directory, "saved.tfplan");
    if (action === "apply") await writeFile(savedPlan, "");
    const args = ["ops/tofu-gate.sh", action, "foundation", "fixture-state"];
    if (["plan", "apply"].includes(action)) args.push(savedPlan);
    const result = run(args, env);
    assert.equal(result.status, 65, `${action}: ${result.stderr}`);
  });
}

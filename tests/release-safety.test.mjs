import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
async function scratch(t) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "infra-release-safety-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}
async function executable(dir, name, source) {
  await writeFile(path.join(dir, name), `#!${process.execPath}\n${source}`, {
    mode: 0o700,
  });
}
function run(command, args, env = {}) {
  return spawnSync(command, args, {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function plan(
  service,
  address,
  { actions = ["update"], before = {}, after = {}, ...extra } = {},
) {
  return {
    format_version: "1.2",
    terraform_version: "1.12.1",
    errored: false,
    variables: {
      application_release: {
        value: { rollout: { services: [service], phase: "candidate" } },
      },
    },
    resource_changes: [
      {
        address,
        mode: "managed",
        type: address.split(".")[0],
        change: { actions, before, after, after_unknown: {}, ...extra },
      },
    ],
  };
}

test("effective plans reject unselected API templates, jobs, new resources and imports in every phase", async (t) => {
  const dir = await scratch(t);
  for (const [selected, other] of [
    ["json_keys", "authentication"],
    ["authentication", "json_keys"],
  ]) {
    for (const phase of ["candidate", "active"]) {
      for (const [address, change] of [
        [
          `google_cloud_run_v2_service.${other}[0]`,
          {
            before: { template: [{ revision: "old", memory: "512Mi" }] },
            after: { template: [{ revision: "old", memory: "1Gi" }] },
          },
        ],
        [`google_cloud_run_v2_job.application["${other}_migrations"]`, {}],
        [
          `google_tags_location_tag_binding.${other}[0]`,
          { actions: ["delete", "create"] },
        ],
        [
          "google_cloud_run_v2_job.surprise[0]",
          { actions: ["create"], before: null },
        ],
        [
          `google_cloud_run_v2_service.${other}[0]`,
          { actions: ["no-op"], importing: { id: "private-import" } },
        ],
      ]) {
        const value = plan(selected, address, change);
        value.variables.application_release.value.rollout.phase = phase;
        const file = path.join(dir, "plan.json");
        await writeFile(file, JSON.stringify(value));
        const result = run(
          "bash",
          [path.join(root, "ops/plan-summary.sh"), "release", file],
          {
            ALLOW_RESOURCE_DELETION: "true",
            RELEASE_PLAN_SERVICES: JSON.stringify([selected]),
          },
        );
        assert.equal(result.status, 65, result.stderr);
        assert.match(result.stderr, /outside the selected service/);
        assert.doesNotMatch(
          result.stdout + result.stderr,
          /private-import|512Mi|1Gi|surprise/,
        );
      }
    }
  }
});

test("selected resource changes and selected schedule toggles are allowed, not configuration changes", async (t) => {
  const dir = await scratch(t);
  const schedule = 'google_cloud_scheduler_job.postgres_backup["json_keys"]';
  const before = {
    name: "agora-postgres-backup-json-keys",
    project: "fixture",
    region: "europe-west1",
    paused: false,
    state: "ENABLED",
    schedule: "45 */4 * * *",
    time_zone: "Etc/UTC",
    http_target: [{ uri: "https://fixture" }],
  };
  for (const phase of ["candidate", "active"]) {
    for (const invalid of [false, "target", "unknown", "frequency"]) {
      const after = { ...before, paused: phase === "candidate", state: null };
      const value = plan("json_keys", schedule, {
        before: { ...before, paused: phase !== "candidate" },
        after,
        after_unknown: { state: true },
      });
      value.variables.application_release.value.rollout.phase = phase;
      value.variables.recovery_mode = { value: false };
      value.variables.workload_project_id = { value: "fixture" };
      value.variables.region = { value: "europe-west1" };
      if (invalid === "target") after.http_target = [{ uri: "https://other" }];
      if (invalid === "unknown")
        value.resource_changes[0].change.after_unknown.http_target = true;
      if (invalid === "frequency") after.schedule = "* * * * *";
      const file = path.join(dir, "plan.json");
      await writeFile(file, JSON.stringify(value));
      const result = run(
        "bash",
        [path.join(root, "ops/plan-summary.sh"), "release", file],
        { RELEASE_PLAN_SERVICES: '["json_keys"]' },
      );
      assert.equal(result.status, invalid ? 65 : 0, result.stderr);
    }
  }
  for (const service of ["json_keys", "authentication"]) {
    const value = plan(service, `google_cloud_run_v2_service.${service}[0]`);
    value.resource_changes.push({
      ...plan(service, "google_cloud_run_v2_job.unselected[0]", {
        actions: ["no-op"],
      }).resource_changes[0],
    });
    const file = path.join(dir, "selected.json");
    await writeFile(file, JSON.stringify(value));
    assert.equal(
      run("bash", [path.join(root, "ops/plan-summary.sh"), "release", file], {
        RELEASE_PLAN_SERVICES: JSON.stringify([service]),
      }).status,
      0,
    );
    value.variables.application_release.value.rollout.services = [
      "json_keys",
      "authentication",
    ];
    value.resource_changes[0].address = "google_cloud_run_v2_service.other[0]";
    await writeFile(file, JSON.stringify(value));
    assert.equal(
      run("bash", [path.join(root, "ops/plan-summary.sh"), "release", file], {
        RELEASE_PLAN_SERVICES: '["json_keys","authentication"]',
      }).status,
      0,
      "full-state maintenance remains permitted",
    );
  }
});

test("PR assessments stay full-graph while deploy plans must match their compiler scope", async (t) => {
  const dir = await scratch(t);
  const file = path.join(dir, "plan.json");
  await writeFile(
    file,
    JSON.stringify(
      plan("authentication", "google_cloud_run_v2_service.json_keys[0]"),
    ),
  );
  assert.equal(
    run("bash", [path.join(root, "ops/plan-summary.sh"), "release", file], {
      RELEASE_PLAN_SERVICES: "",
    }).status,
    0,
  );
  for (const expected of [
    '["json_keys"]',
    '["json_keys","authentication"]',
    "null",
    "not-json",
  ]) {
    assert.equal(
      run("bash", [path.join(root, "ops/plan-summary.sh"), "release", file], {
        RELEASE_PLAN_SERVICES: expected,
      }).status,
      65,
    );
  }
});

test("saved plan apply rechecks scope and never calls tofu apply on violation", async (t) => {
  const dir = await scratch(t);
  const file = path.join(dir, "plan.json");
  await writeFile(
    file,
    JSON.stringify(
      plan("authentication", "google_cloud_run_v2_service.json_keys[0]"),
    ),
  );
  await executable(dir, "git", "process.exit(0)");
  await executable(
    dir,
    "tofu",
    `const fs = require('node:fs'); const args = process.argv.slice(2); const action = args.find(x => !x.startsWith('-'));
if (action === 'show') process.stdout.write(fs.readFileSync(process.env.FIXTURE_PLAN));
else if (action === 'apply') { fs.writeFileSync(process.env.CALL_LOG, 'unexpected apply'); process.exit(99); }
else if (action !== 'init') process.exit(99);`,
  );
  const result = run(
    "bash",
    [
      path.join(root, "ops/tofu-gate.sh"),
      "apply",
      "release",
      "fixture-state",
      file,
    ],
    {
      PATH: `${dir}:${process.env.PATH}`,
      FIXTURE_PLAN: file,
      CALL_LOG: path.join(dir, "calls"),
      ALLOW_RESOURCE_DELETION: "true",
      RELEASE_PLAN_SERVICES: '["authentication"]',
    },
  );
  assert.equal(result.status, 65, result.stderr);
  await assert.rejects(readFile(path.join(dir, "calls")), { code: "ENOENT" });
});

async function driverFixture(t) {
  const dir = await scratch(t);
  await copyFile(
    path.join(root, "ops/google-release-driver.sh"),
    path.join(dir, "driver.sh"),
  );
  const release = {
    cloud: {
      workloadProjectId: "fixture-project",
      region: "europe-west1",
      databaseZone: "europe-west1-d",
    },
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    mode: "service",
    services: ["json_keys"],
    revisions: { jsonKeys: "agora-json-keys-grpc-new" },
    images: [
      {
        component: "service-json-keys",
        slot: "grpc",
        promoted: `europe-west1-docker.pkg.dev/fixture-project/agora-production/service-json-keys/grpc@sha256:${"a".repeat(64)}`,
      },
    ],
  };
  await writeFile(path.join(dir, "release.json"), JSON.stringify(release));
  await writeFile(
    path.join(dir, "operations.json"),
    JSON.stringify({ executions: {}, health: { jsonKeys: "not-run" } }),
  );
  const env = {
    PATH: `${dir}:${process.env.PATH}`,
    RELEASE_DIRECTORY: dir,
    STATE_BUCKET: "fixture-state",
    RECEIPT_BUCKET: "fixture-receipts",
    GITHUB_SHA: release.commit,
    GITHUB_RUN_ID: release.runId,
    GITHUB_RUN_ATTEMPT: "1",
    CALL_LOG: path.join(dir, "calls"),
  };
  return {
    dir,
    release,
    env,
    invoke: (step, extra = {}) =>
      run("bash", [path.join(dir, "driver.sh"), step], { ...env, ...extra }),
  };
}

test("the driver previews activation and compensation before saving and applying the candidate plan", async (t) => {
  for (const failure of ["", "active", "rollback", "candidate"]) {
    const f = await driverFixture(t);
    for (const helper of [
      "tofu-gate.sh",
      "create-reviewed-plan.sh",
      "apply-reviewed-plan.sh",
    ]) {
      await executable(
        f.dir,
        helper,
        `const fs = require('node:fs'); const helper = ${JSON.stringify(helper)};
if (process.env.RELEASE_PLAN_SERVICES !== '["json_keys"]') process.exit(99);
const phase = helper === 'tofu-gate.sh' ? (process.env.TOFU_VAR_FILE.includes('/rollback.') ? 'rollback' : 'active') : 'candidate';
fs.appendFileSync(process.env.CALL_LOG, helper + ':' + phase + '\\n');
if (process.env.FAIL_PHASE === phase) process.exit(65);`,
      );
    }
    const result = f.invoke("plan", { FAIL_PHASE: failure });
    assert.equal(result.status, failure ? 65 : 0, result.stderr);
    const calls = await readFile(f.env.CALL_LOG, "utf8");
    const expected = [
      "tofu-gate.sh:active",
      "tofu-gate.sh:rollback",
      "create-reviewed-plan.sh:candidate",
    ];
    assert.equal(
      calls.trim(),
      expected
        .slice(
          0,
          failure
            ? ["active", "rollback", "candidate"].indexOf(failure) + 1
            : 3,
        )
        .join("\n"),
    );
    assert.doesNotMatch(calls, /apply-reviewed/);
    if (!failure) {
      assert.equal(f.invoke("candidate").status, 0);
      assert.equal(
        (await readFile(f.env.CALL_LOG, "utf8")).trim(),
        [...expected, "apply-reviewed-plan.sh:candidate"].join("\n"),
      );
    }
  }
});

test("JSON Keys smoke requires a successful exact-candidate application probe, not merely Ready", async (t) => {
  for (const failure of [
    "",
    "unhealthy",
    "revision",
    "target",
    "audience",
    "image",
    "identity",
    "not-ready",
  ]) {
    const f = await driverFixture(t);
    await executable(
      f.dir,
      "gcloud",
      `const fs = require('node:fs'); const args = process.argv.slice(2); const failure = process.env.FAILURE;
if (!args.includes('--project=fixture-project') || !args.includes('--region=europe-west1')) process.exit(99);
const release = JSON.parse(fs.readFileSync(process.env.RELEASE_DIRECTORY + '/release.json'));
const url = 'https://agora-json-keys-grpc-fixture-ew.a.run.app'; const target = url.replace('https://', 'https://candidate---');
switch (args.slice(0, 3).join(' ')) {
case 'run revisions describe': console.log(JSON.stringify({ status: { conditions: [{ type: 'Ready', status: failure === 'not-ready' ? 'False' : 'True' }] } })); break;
case 'run services describe': console.log(JSON.stringify({ status: { url, traffic: [{ tag: 'candidate', revisionName: failure === 'revision' ? 'old' : release.revisions.jsonKeys, url: target, percent: 0 }] } })); break;
case 'run jobs describe': console.log(JSON.stringify({ spec: { template: { spec: { template: { spec: { serviceAccountName: failure === 'identity' ? 'agora-authentication@fixture-project.iam.gserviceaccount.com' : 'agora-json-keys@fixture-project.iam.gserviceaccount.com', containers: [{ image: failure === 'image' ? 'wrong' : release.images[0].promoted, env: [{ name: 'JSON_KEYS_AUDIENCE', value: failure === 'audience' ? target : url }, { name: 'JSON_KEYS_CANDIDATE', value: failure === 'target' ? url : target }] }] } } } } } })); break;
case 'run jobs execute':
  if (args[3] !== 'agora-json-keys-smoke' || !args.includes('--wait') || args.some(x => x.includes('override'))) process.exit(99);
  fs.appendFileSync(process.env.CALL_LOG, 'probe\\n');
  if (failure === 'unhealthy') process.exit(1);
  console.log('agora-json-keys-smoke-abcde'); break;
default: process.exit(99);
}`,
    );
    const result = f.invoke("json-smoke", { FAILURE: failure });
    assert.equal(result.status, failure ? 70 : 0, result.stderr);
    const operations = JSON.parse(
      await readFile(path.join(f.dir, "operations.json"), "utf8"),
    );
    assert.equal(operations.health.jsonKeys, failure ? "not-run" : "passed");
    if (!failure)
      assert.equal(
        operations.executions.jsonKeysSmoke,
        "agora-json-keys-smoke-abcde",
      );
    if (failure && failure !== "unhealthy")
      await assert.rejects(readFile(f.env.CALL_LOG), { code: "ENOENT" });
  }
});

test("the in-VPC probe returns the application RPC status and keeps tokens out of logs and arguments", async (t) => {
  const dir = await scratch(t);
  await executable(
    dir,
    "wget",
    `if (!process.argv.includes('--header=Metadata-Flavor: Google')) process.exit(99); process.stdout.write('fixture-private-token');`,
  );
  await executable(
    dir,
    "grpcurl",
    `const assert = require('node:assert/strict'); const args = process.argv.slice(2);
assert.ok(args.includes('anovel.jsonkeys.v2.StatusService/Status'));
assert.ok(args.includes('candidate---fixture.run.app:443'));
assert.ok(args.includes('-expand-headers'));
assert.ok(!args.join(' ').includes('fixture-private-token'));
assert.equal(process.env.IDENTITY_TOKEN, 'fixture-private-token');
console.log('fixture-private-response'); console.error('fixture-private-error');
process.exit(Number(process.env.RPC_CODE));`,
  );
  for (const code of [0, 1, 14]) {
    const result = run(
      "sh",
      [
        path.join(
          root,
          "environments/production/release/scripts/json-keys-smoke.sh",
        ),
      ],
      {
        PATH: `${dir}:${process.env.PATH}`,
        JSON_KEYS_AUDIENCE: "https://fixture.run.app",
        JSON_KEYS_CANDIDATE: "https://candidate---fixture.run.app",
        RPC_CODE: String(code),
      },
    );
    assert.equal(result.status, code);
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-private/);
    assert.equal(result.stdout.includes("health passed"), code === 0);
  }
});

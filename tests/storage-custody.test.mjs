import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bucket = "custody-test";
const markerName = "production/initialization/1001/complete.json";
const marker = {
  schemaVersion: 2,
  project: "workload-test",
  dataDiskId: "1001",
  commit: "a".repeat(40),
  execution: "agora-authentication-init-previous",
  completedAt: "2026-09-04T22:58:33Z",
};

async function custody(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "infra-custody-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await symlink(
    path.join(root, "tests/fixtures/fake-gcloud-storage.sh"),
    path.join(directory, "gcloud"),
  );
  const output = path.join(directory, "output.json");
  return {
    directory,
    output,
    async put(name, value) {
      const target = path.join(directory, "gcs", bucket, name);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, value);
    },
    run(script, args, env = {}) {
      return spawnSync("bash", [path.join(root, "ops", script), ...args], {
        encoding: "utf8",
        timeout: 10000,
        env: {
          ...process.env,
          PATH: `${directory}:${process.env.PATH}`,
          FAKE_GCS_ROOT: path.join(directory, "gcs"),
          FAKE_GCS_LIST_FAILURE: "false",
          FAKE_GCS_READ_FAILURE: "false",
          FAKE_GCS_LOST_UPLOAD_RESPONSE: "false",
          TOFU_STATE_SUFFIX: "",
          INITIALIZATION_MAX_POLLS: "1",
          INITIALIZATION_POLL_SECONDS: "0",
          ...env,
        },
      });
    },
  };
}

const initializerArgs = [
  "workload-test",
  "europe-west1",
  bucket,
  "b".repeat(40),
  "1001",
];

test("initialization reuses an existing marker from an earlier commit without a live job", async (t) => {
  const store = await custody(t);
  await store.put(markerName, JSON.stringify(marker));
  const result = store.run("await-auth-initialization.sh", initializerArgs);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), marker.execution);
  assert.equal(result.stderr, "");
});

test("only the exact completion marker bypasses the human initialization gate", async (t) => {
  const store = await custody(t);
  await store.put(`${markerName}.backup`, JSON.stringify(marker));
  const result = store.run("await-auth-initialization.sh", initializerArgs);
  assert.equal(result.status, 70);
  assert.match(result.stderr, /one-time, human-only initialization/);
});

test("a legacy shared-disk marker cannot skip initialization on a fresh disk", async (t) => {
  const store = await custody(t);
  await store.put(
    "production/initialization/complete.json",
    JSON.stringify({ ...marker, schemaVersion: 1 }),
  );
  const result = store.run("await-auth-initialization.sh", initializerArgs);
  assert.equal(result.status, 70);
  assert.match(result.stderr, /one-time, human-only initialization/);
});

for (const field of ["project", "dataDiskId"]) {
  test(
    "initialization rejects a marker bound to the wrong " + field,
    async (t) => {
      const store = await custody(t);
      await store.put(
        markerName,
        JSON.stringify({
          ...marker,
          [field]: field === "project" ? "other-project" : "9999",
        }),
      );
      const result = store.run("await-auth-initialization.sh", initializerArgs);
      assert.equal(result.status, 70);
      assert.match(result.stderr, /marker is invalid/);
    },
  );
}

test("an invalid initialization marker stops without requesting reinitialization", async (t) => {
  const store = await custody(t);
  await store.put(
    markerName,
    JSON.stringify({ ...marker, execution: "wrong-job" }),
  );
  const result = store.run("await-auth-initialization.sh", initializerArgs);
  assert.equal(result.status, 70);
  assert.match(result.stderr, /marker is invalid/);
  assert.doesNotMatch(result.stderr, /one-time, human-only initialization/);
});

for (const failure of ["FAKE_GCS_LIST_FAILURE", "FAKE_GCS_READ_FAILURE"]) {
  test(`initialization fails closed on ${failure}`, async (t) => {
    const store = await custody(t);
    await store.put(markerName, JSON.stringify(marker));
    const result = store.run("await-auth-initialization.sh", initializerArgs, {
      [failure]: "true",
    });
    assert.equal(result.status, 70);
    assert.match(result.stderr, /could not be (listed|read)/);
    assert.doesNotMatch(result.stderr, /one-time, human-only initialization/);
  });
}

function receipt(runId, runAttempt) {
  return {
    schemaVersion: 1,
    kind: "deployment",
    createdAt: "2026-09-04T22:58:33Z",
    sequence: { runId, runAttempt },
    source: { commit: "a".repeat(40), manifestSha256: "b".repeat(64) },
    activeTfvars: {},
    database: null,
    operations: {
      executions: {
        jsonKeysMigrations: null,
        jsonKeysRotation: null,
        authenticationMigrations: null,
        postgresBackupJsonKeys: null,
        postgresBackupAuthentication: null,
        postgresRestoreJsonKeys: null,
        postgresRestoreAuthentication: null,
        postgresBackupMonitor: null,
      },
      initialization: null,
      health: { jsonKeys: "not-run", authentication: "not-run" },
    },
  };
}

const planCommit = "a".repeat(40);
const planId = "101-1";
const planIdentity = [bucket, "foundation", planCommit, planId];

test("saved plans preserve private content and cannot cross recovery namespaces or replay after consumption", async (t) => {
  const store = await custody(t);
  const content = Buffer.from("opaque\0plan\xff", "latin1");
  await writeFile(store.output, content);
  const run = (action, args = [], suffix = "recovery/agora-recovery-test") =>
    store.run("plan-custody.sh", [action, ...planIdentity, ...args], {
      TOFU_STATE_SUFFIX: suffix,
    });
  assert.equal(run("publish", [store.output, "false"]).status, 0);
  const fetched = `${store.output}.fetched`;
  assert.equal(
    run("fetch", [fetched], "recovery/different-recovery").status,
    66,
  );
  const result = run("fetch", [fetched]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(await readFile(fetched), content);
  assert.equal(
    (await readFile(`${fetched}.destructive`, "utf8")).trim(),
    "false",
  );
  for (const file of [fetched, `${fetched}.destructive`])
    assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal(run("consume").status, 0);
  assert.equal(run("fetch", [fetched]).status, 66);
});

for (const fails of [false, true]) {
  test(`a ${fails ? "failed" : "successful"} apply consumes the saved plan before mutation and prevents replay`, async (t) => {
    const store = await custody(t);
    await writeFile(store.output, "opaque-plan");
    assert.equal(
      store.run("plan-custody.sh", [
        "publish",
        ...planIdentity,
        store.output,
        "false",
      ]).status,
      0,
    );
    await symlink(
      path.join(root, "tests/fixtures/fake-tofu.sh"),
      path.join(store.directory, "tofu"),
    );
    await writeFile(
      path.join(store.directory, "git"),
      "#!/bin/bash\nexit 0\n",
      { mode: 0o700 },
    );
    const config = path.join(store.directory, "config.json");
    await writeFile(config, "{}");
    const remotePlan = path.join(
      store.directory,
      "gcs",
      bucket,
      "foundation/plans",
      planCommit,
      planId,
      "plan.tfplan",
    );
    const result = store.run(
      "apply-reviewed-plan.sh",
      ["foundation", bucket, planCommit, planId, config],
      {
        FAKE_TOFU_PLAN_CODE: "0",
        FAKE_TOFU_PLAN_JSON: path.join(root, "tests/fixtures/plans/safe.json"),
        FAKE_TOFU_REQUIRE_ABSENT: remotePlan,
        FAKE_TOFU_FAIL_ACTION: fails ? "apply" : "",
        GITHUB_REPOSITORY: "a-novel/infra",
      },
    );
    assert.equal(result.status, fails ? 1 : 0, result.stderr);
    if (fails) assert.match(result.stderr, /Protected OpenTofu apply failed/);
    assert.doesNotMatch(
      result.stdout + result.stderr,
      /fixture-sensitive-diagnostic/,
    );
    await assert.rejects(stat(remotePlan), { code: "ENOENT" });
    assert.equal(
      store.run("plan-custody.sh", ["fetch", ...planIdentity, store.output])
        .status,
      66,
    );
  });
}

test("receipt publication accepts newer attempts and refuses delayed older runs or attempts", async (t) => {
  const store = await custody(t);
  for (const [run, attempt, status] of [
    ["200", 1, 0],
    ["200", 2, 0],
    ["100", 1, 70],
    ["200", 1, 70],
  ]) {
    await writeFile(store.output, JSON.stringify(receipt(run, attempt)));
    const result = store.run("receipt-custody.sh", [
      "publish",
      bucket,
      store.output,
      run,
      String(attempt),
    ]);
    assert.equal(result.status, status, result.stderr);
  }
  const result = store.run("receipt-custody.sh", [
    "fetch",
    bucket,
    store.output,
    "200-2",
  ]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(
    JSON.parse(await readFile(store.output, "utf8")),
    receipt("200", 2),
  );
});

test("a lost receipt upload response accepts identical bytes but rejects a conflicting immutable receipt", async (t) => {
  const store = await custody(t);
  const original = JSON.stringify(receipt("300", 1));
  const args = ["publish", bucket, store.output, "300", "1"];
  await writeFile(store.output, original);
  const result = store.run("receipt-custody.sh", args, {
    FAKE_GCS_LOST_UPLOAD_RESPONSE: "true",
  });
  assert.equal(result.status, 0, result.stderr);
  await writeFile(store.output, `${original}\n`);
  assert.equal(store.run("receipt-custody.sh", args).status, 70);
  assert.equal(
    store.run("receipt-custody.sh", ["fetch", bucket, store.output, "300-1"])
      .status,
    0,
  );
  assert.equal(await readFile(store.output, "utf8"), original);
});

for (const kind of ["config", "receipt"]) {
  const script = `${kind}-custody.sh`;
  const prefix = kind === "config" ? "foundation/config" : "production/success";
  const extension = kind === "config" ? "tfvars.json" : "json";
  const args = (output) =>
    kind === "config"
      ? ["fetch", bucket, "foundation", output]
      : ["latest", bucket, output];
  const value = (run, attempt) =>
    kind === "config"
      ? { selected: `${run}-${attempt}` }
      : receipt(run, attempt);

  test(`${kind} lookup selects the newest run and attempt using object names`, async (t) => {
    const store = await custody(t);
    for (const [run, attempt] of [
      ["100", 1],
      ["200", 1],
      ["200", 2],
    ]) {
      await store.put(
        `${prefix}/${run.padStart(20, "0")}-${String(attempt).padStart(5, "0")}.${extension}`,
        JSON.stringify(value(run, attempt)),
      );
    }
    const result = store.run(script, args(store.output));
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(
      JSON.parse(await readFile(store.output, "utf8")),
      value("200", 2),
    );
    assert.equal((await stat(store.output)).mode & 0o777, 0o600);
  });

  test(`${kind} lookup distinguishes an empty inventory from denied access`, async (t) => {
    const store = await custody(t);
    assert.equal(store.run(script, args(store.output)).status, 4);
    const denied = store.run(script, args(store.output), {
      FAKE_GCS_LIST_FAILURE: "true",
    });
    assert.equal(denied.status, 70);
    assert.match(denied.stderr, /inventory could not be listed/);
  });

  test(`${kind} lookup rejects an unexpected object name`, async (t) => {
    const store = await custody(t);
    await store.put(`${prefix}/unexpected.json`, "{}");
    const result = store.run(script, args(store.output));
    assert.equal(result.status, 70);
    assert.match(result.stderr, /unexpected object/);
  });
}

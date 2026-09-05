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
const markerName = "production/initialization/complete.json";
const marker = {
  schemaVersion: 1,
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

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { compileRelease, infra } from "./helpers/infra.mjs";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));
const executeFile = promisify(execFile);

test("recovery compiler feeds exact secret pins and replacement quotas to preflight", async (t) => {
  const scratch = await mkdtemp(path.join(os.tmpdir(), "infra-recovery-test-"));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const releaseOutput = path.join(scratch, "source-release");
  const compiled = await compileRelease({
    manifestPath: path.join(
      repositoryRoot,
      "tests/fixtures/manifests/valid.yaml",
    ),
    configPath: path.join(repositoryRoot, "tests/fixtures/release-config.json"),
    outputDirectory: releaseOutput,
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
  });
  const receipt = {
    schemaVersion: 1,
    kind: "deployment",
    createdAt: "2026-08-25T12:00:00Z",
    sequence: { runId: "123", runAttempt: 1 },
    source: {
      commit: "a".repeat(40),
      manifestSha256: compiled.release.manifestSha256,
    },
    activeTfvars: compiled.activeTfvars,
    database: compiled.release.database,
    operations: {
      executions: {
        jsonKeysMigrations: "json-migration-test",
        jsonKeysRotation: "json-rotation-test",
        authenticationMigrations: "auth-migration-test",
        postgresBackupJsonKeys: "postgres-backup-json-test",
        postgresBackupAuthentication: "postgres-backup-auth-test",
        postgresRestoreJsonKeys: "postgres-restore-json-test",
        postgresRestoreAuthentication: "postgres-restore-auth-test",
        postgresBackupMonitor: "postgres-backup-monitor-test",
      },
      initialization: "agora-authentication-init-test",
      health: { jsonKeys: "passed", authentication: "passed" },
    },
  };
  const foundationConfigPath = path.join(scratch, "foundation.json");
  const receiptPath = path.join(scratch, "receipt.json");
  const outputsPath = path.join(scratch, "outputs.json");
  const recoveryOutput = path.join(scratch, "recovery");
  await Promise.all([
    writeFile(
      foundationConfigPath,
      JSON.stringify({
        management_project_id: "agora-management-test",
        workload_project_id: "agora-production-test",
        region: "europe-west1",
        backup_bucket_name: "agora-management-test-123456789012-backups",
      }),
    ),
    writeFile(receiptPath, JSON.stringify(receipt)),
    writeFile(
      outputsPath,
      JSON.stringify({
        workload_project_id: { value: "agora-recovery-test" },
        network: {
          value: {
            network_id:
              "projects/agora-recovery-test/global/networks/agora-production",
            subnet_id:
              "projects/agora-recovery-test/regions/europe-west1/subnetworks/agora-production-europe-west1",
          },
        },
        database_hosts: {
          value: {
            authentication: {
              private_ip: "10.20.0.8",
              data_disk: { id: "2001" },
            },
            json_keys: { private_ip: "10.20.0.9", data_disk: { id: "2002" } },
          },
        },
        cloud_run_invocation_tags: {
          value: {
            key: "tagKeys/300000000001",
            values: {
              initializer: "tagValues/400000000001",
              internal: "tagValues/400000000002",
              recovery: "tagValues/400000000003",
              release: "tagValues/400000000004",
              scheduled: "tagValues/400000000005",
            },
          },
        },
      }),
    ),
  ]);

  await executeFile(
    infra,
    [
      "compile-recovery",
      foundationConfigPath,
      receiptPath,
      outputsPath,
      "agora-recovery-test",
      "1750000000-json-backup-0",
      "1750000001-auth-backup-0",
      "release",
      recoveryOutput,
    ],
    {
      env: {
        ...process.env,
        GITHUB_SHA: "b".repeat(40),
        GITHUB_RUN_ID: "456",
        GITHUB_RUN_ATTEMPT: "1",
      },
    },
  );

  const secretCalls = compiled.release.cloud.secretVersions.map(
    ([secret, version]) => [
      "secrets",
      "versions",
      "describe",
      String(version),
      `--secret=${secret}`,
      "--project=agora-management-test",
      "--format=value(state)",
    ],
  );
  const quotaCall = [
    "quotas",
    "preferences",
    "list",
    "--project=agora-recovery-test",
    "--format=json",
  ];
  const quotas = [
    ["run.googleapis.com", 8000],
    ["run.googleapis.com", 17179869184],
    ["compute.googleapis.com", 4],
  ].map(([service, value]) => ({
    service,
    dimensions: { region: "europe-west1" },
    quotaConfig: { preferredValue: String(value), grantedValue: String(value) },
  }));
  const responsesPath = path.join(scratch, "responses.json");
  const callsPath = path.join(scratch, "calls.jsonl");
  await writeFile(
    responsesPath,
    JSON.stringify([
      ...secretCalls.map((args) => ({ args, stdout: "ENABLED\n" })),
      { args: quotaCall, stdout: JSON.stringify(quotas) },
    ]),
  );
  await writeFile(
    path.join(scratch, "gcloud"),
    `#!${process.execPath}
import { appendFileSync, readFileSync } from "node:fs";
const args = process.argv.slice(2);
const responses = JSON.parse(readFileSync(process.env.RECOVERY_PREFLIGHT_RESPONSES, "utf8"));
const response = responses.find((entry) => JSON.stringify(entry.args) === JSON.stringify(args));
if (!response) process.exit(64);
appendFileSync(process.env.RECOVERY_PREFLIGHT_CALLS, JSON.stringify(args) + "\\n");
process.stdout.write(response.stdout);
`,
    { mode: 0o700 },
  );
  const { stdout } = await executeFile(
    "bash",
    [
      path.join(repositoryRoot, "ops/preflight-release.sh"),
      path.join(recoveryOutput, "preflight.json"),
    ],
    {
      env: {
        ...process.env,
        PATH: `${scratch}${path.delimiter}${process.env.PATH}`,
        RECOVERY_PREFLIGHT_RESPONSES: responsesPath,
        RECOVERY_PREFLIGHT_CALLS: callsPath,
      },
    },
  );
  assert.match(stdout, /Live secret-version and quota preflight passed/);
  assert.deepEqual(
    (await readFile(callsPath, "utf8")).trim().split("\n").map(JSON.parse),
    [...secretCalls, quotaCall],
  );
});

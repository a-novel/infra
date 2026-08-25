import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import Ajv2020 from "ajv/dist/2020.js";
import { parse } from "yaml";

import { compileRelease } from "../ops/compile-release.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const schemaPath = path.join(
  repositoryRoot,
  "deploy/production/images.schema.json",
);

const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
const executeFile = promisify(execFile);

async function readManifest(relativePath) {
  return parse(await readFile(path.join(repositoryRoot, relativePath), "utf8"));
}

const stableManifest = await readManifest(
  "tests/fixtures/manifests/valid.yaml",
);

function copyStableManifest() {
  return structuredClone(stableManifest);
}

test("the production manifest matches its schema", async () => {
  const manifest = await readManifest("deploy/production/images.yaml");

  assert.equal(validate(manifest), true, JSON.stringify(validate.errors));
});

test("a stable SemVer image with a digest is accepted", async () => {
  assert.equal(
    validate(copyStableManifest()),
    true,
    JSON.stringify(validate.errors),
  );
});

test("a branch image tag is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].images.grpc.tag = "feat-rotate-keys";

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.instancePath.endsWith("/tag")),
  );
});

test("an image without a digest is rejected", () => {
  const manifest = copyStableManifest();
  delete manifest.components["service-authentication"].images.rest.digest;

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "required"));
});

test("an enabled component must include its complete image family", () => {
  const manifest = copyStableManifest();
  delete manifest.components["service-json-keys"].images["jobs/rotatekeys"];

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "required"));
});

test("a standalone image is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-authentication"].images.standalone =
    structuredClone(manifest.components["service-authentication"].images.rest);

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "additionalProperties"),
  );
});

test("an unplanned future image is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].images["jobs/future"] =
    structuredClone(
      manifest.components["service-json-keys"].images["jobs/migrations"],
    );

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "additionalProperties"),
  );
});

test("an image repository must match its exact runtime slot", () => {
  const manifest = copyStableManifest();
  manifest.components["service-authentication"].images.rest.repository =
    "ghcr.io/a-novel/service-authentication/database";

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "const"));
});

test("the PostgreSQL major is explicit and fixed", () => {
  const manifest = copyStableManifest();
  manifest.postgresMajor = 17;

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.instancePath === "/postgresMajor"),
  );
});

test("release compilation rejects mixed versions in one component", async () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].images.grpc.tag = "v2.5.1";
  const scratch = await mkdtemp(path.join(repositoryRoot, ".release-test-"));
  const manifestPath = path.join(scratch, "manifest.yaml");
  await writeFile(manifestPath, JSON.stringify(manifest));

  await assert.rejects(
    compileRelease({
      manifestPath,
      configPath: path.join(
        repositoryRoot,
        "tests/fixtures/release-config.json",
      ),
      outputDirectory: path.join(scratch, "out"),
      commit: "a".repeat(40),
      runId: "123",
      runAttempt: 1,
      nonce: "test",
    }),
    /must use one SemVer release/,
  );
  await rm(scratch, { recursive: true });
});

test("release compilation emits candidate, active, and rollback inputs", async () => {
  const scratch = await mkdtemp(path.join(repositoryRoot, ".release-test-"));
  const result = await compileRelease({
    manifestPath: path.join(
      repositoryRoot,
      "tests/fixtures/manifests/valid.yaml",
    ),
    configPath: path.join(repositoryRoot, "tests/fixtures/release-config.json"),
    outputDirectory: scratch,
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    nonce: "test",
  });

  assert.equal(
    result.candidateTfvars.application_release.rollout.phase,
    "candidate",
  );
  assert.equal(result.activeTfvars.application_release.rollout.phase, "active");
  assert.equal(result.rollbackTfvars.application_release, null);
  assert.match(
    result.release.database.jsonKeysImage,
    /^europe-west1-docker\.pkg\.dev\/agora-production-test\//,
  );
  await rm(scratch, { recursive: true });
});

test("a compensated first release remains a valid empty rollback target", async () => {
  const scratch = await mkdtemp(path.join(repositoryRoot, ".release-test-"));
  const firstOutput = path.join(scratch, "first");
  const first = await compileRelease({
    manifestPath: path.join(
      repositoryRoot,
      "tests/fixtures/manifests/valid.yaml",
    ),
    configPath: path.join(repositoryRoot, "tests/fixtures/release-config.json"),
    outputDirectory: firstOutput,
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    nonce: "first",
  });
  const receiptPath = path.join(scratch, "receipt.json");
  await writeFile(
    receiptPath,
    JSON.stringify({
      schemaVersion: 1,
      kind: "rollback",
      createdAt: "2026-08-25T12:00:00Z",
      sequence: { runId: "123", runAttempt: 1 },
      source: {
        commit: "a".repeat(40),
        manifestSha256: first.release.manifestSha256,
      },
      activeTfvars: first.rollbackTfvars,
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
    }),
  );

  const next = await compileRelease({
    manifestPath: path.join(
      repositoryRoot,
      "tests/fixtures/manifests/valid.yaml",
    ),
    configPath: path.join(repositoryRoot, "tests/fixtures/release-config.json"),
    previousReceiptPath: receiptPath,
    outputDirectory: path.join(scratch, "next"),
    commit: "b".repeat(40),
    runId: "124",
    runAttempt: 1,
    nonce: "next",
  });

  assert.equal(next.rollbackTfvars.application_release, null);
  assert.deepEqual(next.rollbackTfvars.database_releases, {});
  await rm(scratch, { recursive: true });
});

test("application-only releases preserve the database release identity", async () => {
  const scratch = await mkdtemp(path.join(repositoryRoot, ".release-test-"));
  const manifestPath = path.join(
    repositoryRoot,
    "tests/fixtures/manifests/valid.yaml",
  );
  const configPath = path.join(
    repositoryRoot,
    "tests/fixtures/release-config.json",
  );
  const first = await compileRelease({
    manifestPath,
    configPath,
    outputDirectory: path.join(scratch, "first"),
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    nonce: "first",
  });
  const receiptPath = path.join(scratch, "receipt.json");
  await writeFile(
    receiptPath,
    JSON.stringify({
      schemaVersion: 1,
      kind: "deployment",
      createdAt: "2026-08-25T12:00:00Z",
      sequence: { runId: "123", runAttempt: 1 },
      source: {
        commit: "a".repeat(40),
        manifestSha256: first.release.manifestSha256,
      },
      activeTfvars: first.activeTfvars,
      database: first.release.database,
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
        health: { jsonKeys: "passed", authentication: "passed" },
      },
    }),
  );

  const unchanged = await compileRelease({
    manifestPath,
    configPath,
    previousReceiptPath: receiptPath,
    outputDirectory: path.join(scratch, "unchanged"),
    commit: "b".repeat(40),
    runId: "124",
    runAttempt: 1,
    nonce: "unchanged",
  });
  assert.deepEqual(unchanged.release.database, first.release.database);

  const changedConfig = JSON.parse(await readFile(configPath, "utf8"));
  changedConfig.secret_versions.json_keys_postgres_backup_password += 1;
  const changedConfigPath = path.join(scratch, "changed-config.json");
  await writeFile(changedConfigPath, JSON.stringify(changedConfig));
  const changed = await compileRelease({
    manifestPath,
    configPath: changedConfigPath,
    previousReceiptPath: receiptPath,
    outputDirectory: path.join(scratch, "changed"),
    commit: "c".repeat(40),
    runId: "125",
    runAttempt: 1,
    nonce: "changed",
  });
  assert.equal(changed.release.database.releaseRevision, "c".repeat(40));
  await rm(scratch, { recursive: true });
});

test("recovery compilation keeps services absent until exact data restore", async () => {
  const scratch = await mkdtemp(path.join(repositoryRoot, ".recovery-test-"));
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
    nonce: "test",
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
        database_host: { value: { private_ip: "10.20.0.8" } },
      }),
    ),
  ]);

  await assert.rejects(
    executeFile(
      process.execPath,
      [
        path.join(repositoryRoot, "ops/compile-recovery.mjs"),
        foundationConfigPath,
        receiptPath,
        "-",
        "agora-management-test",
        "placeholder",
        "placeholder",
        "foundation",
        path.join(scratch, "unsafe-management-target"),
      ],
      {
        env: {
          ...process.env,
          GITHUB_SHA: "b".repeat(40),
          GITHUB_RUN_ID: "456",
          GITHUB_RUN_ATTEMPT: "1",
        },
      },
    ),
  );

  await executeFile(
    process.execPath,
    [
      path.join(repositoryRoot, "ops/compile-recovery.mjs"),
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

  const staging = JSON.parse(
    await readFile(path.join(recoveryOutput, "staging.tfvars.json"), "utf8"),
  );
  const active = JSON.parse(
    await readFile(path.join(recoveryOutput, "active.tfvars.json"), "utf8"),
  );
  assert.equal(staging.application_release, null);
  assert.equal(active.recovery_mode, true);
  assert.equal(active.workload_project_id, "agora-recovery-test");
  assert.equal(active.recovery_source_project_id, "agora-production-test");
  assert.equal(active.recovery_source_database_ip, "10.20.0.2");
  assert.match(
    active.application_release.authentication.images.rest,
    /\/agora-recovery-test\/agora-production\//,
  );
  assert.match(
    active.recovery_database_images.authentication,
    /\/agora-production-test\/agora-production\//,
  );
  await rm(scratch, { recursive: true });
});

test("a disabled component cannot retain deployable images", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].enabled = false;

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "maxProperties"),
  );
});

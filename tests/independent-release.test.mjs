import { compileRelease } from "../ops/compile-release.mjs";

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
  copyFile,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = path.join(root, "tests/fixtures/manifests/valid.yaml");
const configPath = path.join(root, "tests/fixtures/release-config.json");

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "infra-independent-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const options = {
    manifestPath,
    configPath,
    outputDirectory: path.join(directory, "first"),
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    nonce: "first",
  };
  const first = await compileRelease(options);
  const operations = {
    executions: Object.fromEntries(
      [
        "jsonKeysMigrations",
        "jsonKeysRotation",
        "authenticationMigrations",
        "postgresBackupJsonKeys",
        "postgresBackupAuthentication",
        "postgresRestoreJsonKeys",
        "postgresRestoreAuthentication",
        "postgresBackupMonitor",
      ].map((key) => [key, null]),
    ),
    initialization: null,
    health: { jsonKeys: "passed", authentication: "passed" },
  };
  const receipt = {
    schemaVersion: 1,
    kind: "deployment",
    createdAt: "2026-09-09T00:00:00Z",
    sequence: { runId: "123", runAttempt: 1 },
    source: {
      commit: options.commit,
      manifestSha256: first.release.manifestSha256,
    },
    activeTfvars: first.activeTfvars,
    database: first.release.database,
    imageManifest: first.release.imageManifest,
    operations,
  };
  const previousReceiptPath = path.join(directory, "receipt.json");
  await writeFile(previousReceiptPath, JSON.stringify(receipt));
  const next = {
    ...options,
    outputDirectory: path.join(directory, "next"),
    previousReceiptPath,
    commit: "b".repeat(40),
    runId: "124",
    nonce: "next",
  };
  const manifest = parse(await readFile(manifestPath, "utf8"));
  async function change(component, { keepDatabaseDigest = false } = {}) {
    for (const [slot, image] of Object.entries(
      manifest.components[component].images,
    )) {
      image.tag = "v4.0.0";
      if (!keepDatabaseDigest || slot !== "database")
        image.digest = `sha256:3${image.digest.slice(8)}`;
    }
    next.manifestPath = path.join(directory, "next.yaml");
    await writeFile(next.manifestPath, JSON.stringify(manifest));
  }
  return { directory, first, receipt, next, manifest, change };
}

for (const [component, selected, other] of [
  ["service-json-keys", "json_keys", "authentication"],
  ["service-authentication", "authentication", "json_keys"],
]) {
  test(`${component} rollout preserves the other service through candidate, active and compensation`, async (t) => {
    const f = await fixture(t);
    await f.change(component);
    const result = await compileRelease(f.next);
    assert.equal(result.release.mode, "service");
    assert.deepEqual(result.release.services, [selected]);
    for (const tfvars of [
      result.candidateTfvars,
      result.activeTfvars,
      result.rollbackTfvars,
    ]) {
      assert.deepEqual(
        tfvars.application_release[other],
        f.first.activeTfvars.application_release[other],
      );
      assert.deepEqual(
        tfvars.database_releases[other],
        f.first.activeTfvars.database_releases[other],
      );
      assert.deepEqual(tfvars.application_release.rollout.services, [selected]);
    }
    assert.notEqual(
      result.activeTfvars.application_release[selected].revision,
      f.first.activeTfvars.application_release[selected].revision,
    );
    assert.deepEqual(result.release.previousManifest, f.receipt.imageManifest);
  });

  test(`${component} publication can reuse an unchanged database digest under its new version`, async (t) => {
    const f = await fixture(t);
    await f.change(component, { keepDatabaseDigest: true });
    const result = await compileRelease(f.next);
    assert.deepEqual(result.release.services, [selected]);
    assert.deepEqual(result.release.database, f.first.release.database);
  });
}

test("deployment rejects two families even when the PR gate was bypassed", async (t) => {
  const f = await fixture(t);
  await f.change("service-json-keys");
  await f.change("service-authentication");
  await assert.rejects(
    compileRelease(f.next),
    /families must be deployed separately/,
  );
  assert.ok(
    !(await readdir(f.directory)).includes("next"),
    "no mutation inputs are written on rejection",
  );
});

test("deployment rejects mixed versions and mutated existing tags before writing inputs", async (t) => {
  for (const mutateTag of [true, false]) {
    const f = await fixture(t);
    const image = f.manifest.components["service-authentication"].images.rest;
    image.digest = `sha256:${"3".repeat(64)}`;
    if (mutateTag) image.tag = "v4.0.0";
    f.next.manifestPath = path.join(f.directory, "bad.yaml");
    await writeFile(f.next.manifestPath, JSON.stringify(f.manifest));
    await assert.rejects(
      compileRelease(f.next),
      mutateTag ? /one SemVer release/ : /mutates an existing release tag/,
    );
    assert.ok(!(await readdir(f.directory)).includes("next"));
  }
});

test("legacy receipt migration requires a manifest matching all eight active digests", async (t) => {
  const f = await fixture(t);
  delete f.receipt.imageManifest;
  await writeFile(f.next.previousReceiptPath, JSON.stringify(f.receipt));
  await f.change("service-json-keys");
  await assert.rejects(
    compileRelease(f.next),
    /requires its exact image manifest/,
  );
  await assert.rejects(
    compileRelease({ ...f.next, previousManifestPath: f.next.manifestPath }),
    /does not match all eight/,
  );
  const result = await compileRelease({
    ...f.next,
    previousManifestPath: manifestPath,
  });
  assert.deepEqual(result.release.services, ["json_keys"]);
});

test("configuration-only maintenance remains a full-state operation", async (t) => {
  const f = await fixture(t);
  const result = await compileRelease(f.next);
  assert.equal(result.release.mode, "maintenance");
  assert.deepEqual(result.release.services, ["json_keys", "authentication"]);
});

test("one-service image update rejects changes to the other service or shared configuration", async (t) => {
  for (const kind of ["smtp", "backup", "network"]) {
    const f = await fixture(t);
    await f.change("service-json-keys");
    const config = JSON.parse(await readFile(configPath, "utf8"));
    if (kind === "smtp")
      config.authentication.smtp.sender_name = "Another sender";
    if (kind === "backup")
      config.secret_versions.authentication_postgres_backup_password = 2;
    if (kind === "network") config.backup_bucket_name = "another-bucket";
    f.next.configPath = path.join(f.directory, "changed-config.json");
    await writeFile(f.next.configPath, JSON.stringify(config));
    await assert.rejects(
      compileRelease(f.next),
      /deploy configuration separately/,
    );
  }
});

test("compensation preserves the unselected API and records the restored manifest", async (t) => {
  for (const component of ["service-json-keys", "service-authentication"]) {
    for (const keepDatabaseDigest of [true, false]) {
      const f = await fixture(t);
      await f.change(component, { keepDatabaseDigest });
      const compiled = await compileRelease(f.next);
      const driver = path.join(f.directory, "google-release-driver.sh");
      await copyFile(path.join(root, "ops/google-release-driver.sh"), driver);
      await copyFile(
        path.join(root, "ops/build-receipt.mjs"),
        path.join(f.directory, "build-receipt.mjs"),
      );
      await chmod(path.join(f.directory, "build-receipt.mjs"), 0o700);
      const log = path.join(f.directory, "calls.log");
      for (const helper of [
        "create-reviewed-plan.sh",
        "apply-reviewed-plan.sh",
        "config-custody.sh",
        "restore-database-release.sh",
        "receipt-custody.sh",
      ]) {
        await writeFile(
          path.join(f.directory, helper),
          `#!${process.execPath}\nconst fs = require('node:fs'); fs.appendFileSync(process.env.CALL_LOG, '${helper}\\n');`,
          { mode: 0o700 },
        );
      }
      await writeFile(
        path.join(f.directory, "gcloud"),
        `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
if (!args.includes('--project=agora-production-test') || !args.includes('--region=europe-west1')) process.exit(99);
fs.appendFileSync(process.env.CALL_LOG, args.slice(0, 4).join(' ') + '\\n');
if (args.slice(0, 3).join(' ') === 'run services describe') {
  const service = args[3] === 'agora-json-keys-grpc' ? 'json_keys' : 'authentication';
  const tfvars = JSON.parse(fs.readFileSync(process.env.RELEASE_DIRECTORY + '/rollback.tfvars.json'));
  process.stdout.write(JSON.stringify({ status: { traffic: [{ revisionName: tfvars.application_release[service].active_revision, percent: 100 }] } }));
} else if (args.slice(0, 3).join(' ') !== 'run services update-traffic') process.exit(99);
`,
        { mode: 0o700 },
      );
      const result = spawnSync("bash", [driver, "rollback"], {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${f.directory}:${process.env.PATH}`,
          CALL_LOG: log,
          RELEASE_DIRECTORY: f.next.outputDirectory,
          STATE_BUCKET: "fixture-state",
          RECEIPT_BUCKET: "fixture-receipts",
          GITHUB_SHA: f.next.commit,
          GITHUB_RUN_ID: f.next.runId,
          GITHUB_RUN_ATTEMPT: "1",
        },
      });
      assert.equal(result.status, 0, result.stderr);
      const calls = await readFile(log, "utf8");
      const selected =
        component === "service-json-keys"
          ? "agora-json-keys-grpc"
          : "agora-authentication-rest";
      const other =
        component === "service-json-keys"
          ? "agora-authentication-rest"
          : "agora-json-keys-grpc";
      assert.ok(calls.includes(`update-traffic ${selected}`));
      assert.ok(!calls.includes(other));
      assert.equal(
        calls.includes("restore-database-release.sh"),
        !keepDatabaseDigest,
      );
      const receipt = JSON.parse(
        await readFile(
          path.join(f.next.outputDirectory, "rollback-receipt.json"),
          "utf8",
        ),
      );
      assert.deepEqual(receipt.imageManifest, f.receipt.imageManifest);
      assert.deepEqual(receipt.database, f.receipt.database);
      assert.deepEqual(receipt.activeTfvars, compiled.rollbackTfvars);
      const retry = await compileRelease({
        ...f.next,
        previousReceiptPath: path.join(
          f.next.outputDirectory,
          "rollback-receipt.json",
        ),
        runId: "125",
      });
      assert.deepEqual(retry.release.services, compiled.release.services);
    }
  }
});

test("invalid scopes never enter the release driver", async (t) => {
  const f = await fixture(t);
  for (const scope of [
    {},
    { mode: "service", services: ["json_keys", "authentication"] },
    { mode: "service", services: ["shell"] },
    { mode: "maintenance", services: [] },
  ]) {
    const scopeFile = path.join(f.directory, "invalid-scope.json");
    await writeFile(scopeFile, JSON.stringify(scope));
    const log = path.join(f.directory, "unexpected-call.log");
    const result = spawnSync(
      "bash",
      [
        path.join(root, "ops/release-orchestrator.sh"),
        path.join(root, "tests/fixtures/fake-release-driver.sh"),
        scopeFile,
      ],
      { encoding: "utf8", env: { ...process.env, RELEASE_TEST_LOG: log } },
    );
    assert.equal(result.status, 65);
    assert.ok(!(await readdir(f.directory)).includes("unexpected-call.log"));
  }
});

const commonStart = ["preflight", "promote", "database", "candidate"];
const serviceSteps = {
  json_keys: [
    "json-migrations",
    "json-rotation",
    "recovery-verification",
    "json-smoke",
    "json-traffic",
  ],
  authentication: [
    "authentication-migrations",
    "recovery-verification",
    "authentication-initialization",
    "authentication-smoke",
    "authentication-traffic",
  ],
};
for (const service of Object.keys(serviceSteps)) {
  test(`${service} executes and compensates only its selected release graph`, async (t) => {
    const f = await fixture(t);
    const scope = path.join(f.directory, "scope.json");
    await writeFile(
      scope,
      JSON.stringify({ mode: "service", services: [service] }),
    );
    const steps = [
      ...commonStart,
      ...serviceSteps[service],
      "active",
      "receipt",
    ];
    for (const failed of ["", ...steps]) {
      const log = path.join(f.directory, `steps-${failed || "success"}.log`);
      const result = spawnSync(
        "bash",
        [
          path.join(root, "ops/release-orchestrator.sh"),
          path.join(root, "tests/fixtures/fake-release-driver.sh"),
          scope,
        ],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            RELEASE_TEST_LOG: log,
            RELEASE_TEST_FAIL_STEP: failed,
          },
        },
      );
      assert.equal(result.status, failed ? 42 : 0, result.stderr);
      const actual = (await readFile(log, "utf8")).trim().split("\n");
      const expected = failed
        ? steps.slice(0, steps.indexOf(failed) + 1)
        : steps;
      if (failed && steps.indexOf(failed) >= 2) expected.push("rollback");
      assert.deepEqual(actual, expected);
    }
  });
}

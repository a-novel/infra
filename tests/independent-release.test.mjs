import { compileRelease } from "./helpers/infra.mjs";

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
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

test("rebuild compensation idles only mutated new hosts without applying or publishing rollback", async (t) => {
  for (const mutated of [[], ["json_keys"], ["authentication", "json_keys"]]) {
    const f = await fixture(t);
    delete f.receipt.database.hosts;
    delete f.receipt.activeTfvars.database_hosts;
    f.receipt.activeTfvars.database_private_ip = "10.20.0.99";
    await writeFile(f.next.previousReceiptPath, JSON.stringify(f.receipt));
    const compiled = await compileRelease(f.next);
    const driver = path.join(f.directory, "google-release-driver.sh");
    await copyFile(path.join(root, "ops/google-release-driver.sh"), driver);
    const log = path.join(f.directory, "restore-calls.jsonl");
    await writeFile(log, "");
    await writeFile(
      path.join(f.directory, "restore-database-release.sh"),
      `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
if (JSON.parse(fs.readFileSync(args[4])) !== null) process.exit(99);
fs.appendFileSync(process.env.CALL_LOG, JSON.stringify(args.slice(0, 4)) + '\\n');
`,
      { mode: 0o700 },
    );
    // Any attempt to return traffic to old hosts or publish a success fails.
    for (const helper of [
      "gcloud",
      "create-reviewed-plan.sh",
      "apply-reviewed-plan.sh",
      "config-custody.sh",
      "receipt-custody.sh",
      "infra",
    ]) {
      await writeFile(path.join(f.directory, helper), "#!/bin/sh\nexit 99\n", {
        mode: 0o700,
      });
    }
    for (const service of mutated) {
      await writeFile(
        path.join(f.next.outputDirectory, "database-mutated-" + service),
        "",
      );
    }
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
    const calls = (await readFile(log, "utf8"))
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    assert.deepEqual(
      calls,
      compiled.release.services
        .filter((service) => mutated.includes(service))
        .map((service) => [
          "agora-production-test",
          "europe-west1-c",
          service.replaceAll("_", "-"),
          compiled.release.cloud.databaseHosts[service].data_disk_id,
        ]),
    );
    assert.ok(
      !(await readdir(f.next.outputDirectory)).includes(
        "rollback-receipt.json",
      ),
    );
  }
});

for (const service of ["json_keys", "authentication"]) {
  test(
    service +
      " release verifies only its own backup and restore, then the monitor",
    async (t) => {
      const f = await fixture(t);
      await f.change("service-" + service.replaceAll("_", "-"));
      await compileRelease(f.next);
      const log = path.join(f.directory, "jobs.log");
      await writeFile(
        path.join(f.next.outputDirectory, "operations.json"),
        JSON.stringify(f.receipt.operations),
      );
      await writeFile(
        path.join(f.directory, "gcloud"),
        "#!" +
          process.execPath +
          "\n" +
          [
            "const fs = require('node:fs');",
            "const args = process.argv.slice(2);",
            "if (args.slice(0, 3).join(' ') !== 'run jobs execute' || !args.includes('--project=agora-production-test') || !args.includes('--region=europe-west1') || !args.includes('--wait')) process.exit(99);",
            "fs.appendFileSync(process.env.CALL_LOG, args[3] + '\\n');",
            "process.stdout.write(args[3] + '-test');",
          ].join("\n"),
        { mode: 0o700 },
      );
      const result = spawnSync(
        "bash",
        [
          path.join(root, "ops/google-release-driver.sh"),
          "recovery-verification",
        ],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: f.directory + ":" + process.env.PATH,
            CALL_LOG: log,
            RELEASE_DIRECTORY: f.next.outputDirectory,
            STATE_BUCKET: "fixture-state",
            RECEIPT_BUCKET: "fixture-receipts",
            GITHUB_SHA: f.next.commit,
            GITHUB_RUN_ID: f.next.runId,
            GITHUB_RUN_ATTEMPT: "1",
          },
        },
      );
      assert.equal(result.status, 0, result.stderr);
      const slug = service.replaceAll("_", "-");
      assert.deepEqual((await readFile(log, "utf8")).trim().split("\n"), [
        "agora-postgres-backup-" + slug,
        "agora-postgres-restore-" + slug,
        "agora-postgres-backup-monitor",
      ]);
      const operations = JSON.parse(
        await readFile(
          path.join(f.next.outputDirectory, "operations.json"),
          "utf8",
        ),
      );
      const selected = service === "json_keys" ? "JsonKeys" : "Authentication";
      const other = service === "json_keys" ? "Authentication" : "JsonKeys";
      assert.equal(
        operations.executions["postgresBackup" + selected],
        "agora-postgres-backup-" + slug + "-test",
      );
      assert.equal(
        operations.executions["postgresRestore" + selected],
        "agora-postgres-restore-" + slug + "-test",
      );
      assert.equal(operations.executions["postgresBackup" + other], null);
      assert.equal(operations.executions["postgresRestore" + other], null);
    },
  );
}

test("compensation preserves the unselected API and records the restored manifest", async (t) => {
  for (const component of ["service-json-keys", "service-authentication"]) {
    for (const keepDatabaseDigest of [true, false]) {
      const f = await fixture(t);
      await f.change(component, { keepDatabaseDigest });
      const compiled = await compileRelease(f.next);
      const driver = path.join(f.directory, "google-release-driver.sh");
      await copyFile(path.join(root, "ops/google-release-driver.sh"), driver);
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
      const selectedKey =
        component === "service-json-keys" ? "json_keys" : "authentication";
      await writeFile(
        path.join(f.next.outputDirectory, "database-mutated-" + selectedKey),
        "",
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

const commonStart = ["preflight", "promote", "plan", "database", "candidate"];
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
      if (failed && steps.indexOf(failed) >= steps.indexOf("database"))
        expected.push("rollback");
      assert.deepEqual(actual, expected);
    }
  });
}

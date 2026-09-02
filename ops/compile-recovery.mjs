#!/usr/bin/env node

/**
 * Build a disposable recovery foundation and two release phases from one
 * surviving production receipt. The first release phase exposes no service;
 * the second uses fresh revision names only after both exact backups restore.
 */

import { createHash } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

function fail(message) {
  throw new Error(message);
}

async function readJson(file, label) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch {
    fail(`${label} is invalid`);
  }
}

async function writePrivate(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await chmod(file, 0o600);
}

function replaceProjectInImage(image, region, sourceProject, targetProject) {
  const prefix = `${region}-docker.pkg.dev/${sourceProject}/agora-production/`;
  if (typeof image !== "string" || !image.startsWith(prefix)) {
    fail("receipt image is outside its original immutable registry");
  }
  return `${region}-docker.pkg.dev/${targetProject}/agora-production/${image.slice(prefix.length)}`;
}

function mapImages(value, region, sourceProject, targetProject) {
  if (Array.isArray(value)) {
    return value.map((item) =>
      mapImages(item, region, sourceProject, targetProject),
    );
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        mapImages(item, region, sourceProject, targetProject),
      ]),
    );
  }
  if (
    typeof value === "string" &&
    value.includes("-docker.pkg.dev/") &&
    value.includes("@sha256:")
  ) {
    return replaceProjectInImage(value, region, sourceProject, targetProject);
  }
  return value;
}

function runtimeAccounts(project) {
  return {
    authentication: `agora-authentication@${project}.iam.gserviceaccount.com`,
    backup: `agora-backup@${project}.iam.gserviceaccount.com`,
    json_keys: `agora-json-keys@${project}.iam.gserviceaccount.com`,
    restore: `agora-restore@${project}.iam.gserviceaccount.com`,
    scheduler_invoker: `agora-scheduler-invoker@${project}.iam.gserviceaccount.com`,
  };
}

function outputValue(outputs, name) {
  if (!outputs[name] || !("value" in outputs[name])) {
    fail(`foundation output ${name} is absent`);
  }
  return outputs[name].value;
}

async function main() {
  if (process.argv.length !== 10) {
    fail(
      "usage: compile-recovery.mjs <foundation-config> <receipt> <foundation-outputs-or-> <replacement-project> <json-attempt> <auth-attempt> <phase> <output-directory>",
    );
  }
  const [
    ,
    ,
    foundationConfigPath,
    receiptPath,
    foundationOutputsPath,
    targetProject,
    jsonAttempt,
    authenticationAttempt,
    phase,
    outputDirectory,
  ] = process.argv;

  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(targetProject)) {
    fail("replacement project ID is invalid");
  }
  if (!new Set(["foundation", "release"]).has(phase)) {
    fail("recovery compilation phase is invalid");
  }

  const [foundationConfig, receipt] = await Promise.all([
    readJson(foundationConfigPath, "foundation configuration"),
    readJson(receiptPath, "selected release receipt"),
  ]);
  const sourceTfvars = receipt.activeTfvars;
  const sourceProject = sourceTfvars?.workload_project_id;
  const managementProject = sourceTfvars?.management_project_id;
  const region = sourceTfvars?.region;
  if (
    receipt.schemaVersion !== 1 ||
    receipt.database === null ||
    sourceTfvars?.application_release === null ||
    !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(sourceProject) ||
    !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(managementProject) ||
    sourceProject === targetProject ||
    managementProject === targetProject
  ) {
    fail("selected receipt is not a recoverable application state");
  }
  if (
    foundationConfig.management_project_id !== managementProject ||
    foundationConfig.workload_project_id !== sourceProject ||
    foundationConfig.region !== region ||
    foundationConfig.backup_bucket_name !== sourceTfvars.backup_bucket_name
  ) {
    fail("recovery foundation configuration does not match the source receipt");
  }

  const recoveryFoundation = {
    ...foundationConfig,
    workload_project_id: targetProject,
    workload_project_name: "Agora recovery",
    recovery_mode: true,
  };
  await mkdir(outputDirectory, { recursive: true, mode: 0o700 });
  await chmod(outputDirectory, 0o700);
  await writePrivate(
    path.join(outputDirectory, "foundation.tfvars.json"),
    recoveryFoundation,
  );
  if (phase === "foundation") return;

  if (
    !/^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$/.test(jsonAttempt) ||
    !/^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$/.test(authenticationAttempt)
  ) {
    fail("exact recovery attempt is invalid");
  }
  const outputs = await readJson(
    foundationOutputsPath,
    "recovery foundation outputs",
  );
  const outputProject = outputValue(outputs, "workload_project_id");
  const network = outputValue(outputs, "network");
  const databaseHost = outputValue(outputs, "database_host");
  const cloudRunInvocationTags = outputValue(
    outputs,
    "cloud_run_invocation_tags",
  );
  if (outputProject !== targetProject) {
    fail("recovery state identifies a different replacement project");
  }

  const transformed = mapImages(
    structuredClone(sourceTfvars),
    region,
    sourceProject,
    targetProject,
  );
  transformed.workload_project_id = targetProject;
  transformed.database_private_ip = databaseHost.private_ip;
  transformed.network_id = network.network_id;
  transformed.subnet_id = network.subnet_id;
  transformed.cloud_run_invocation_tags = cloudRunInvocationTags;
  transformed.runtime_service_accounts = runtimeAccounts(targetProject);
  transformed.recovery_mode = true;
  transformed.recovery_source_project_id = sourceProject;
  transformed.recovery_source_database_ip = sourceTfvars.database_private_ip;
  transformed.recovery_database_images = {
    authentication: receipt.database.authenticationImage,
    json_keys: receipt.database.jsonKeysImage,
  };
  transformed.recovery_backup_attempts = {
    authentication: authenticationAttempt,
    json_keys: jsonAttempt,
  };
  transformed.recovery_database_password_versions = {
    authentication: receipt.database.authenticationPasswordVersion,
    json_keys: receipt.database.jsonKeysPasswordVersion,
  };

  const seed = createHash("sha256")
    .update(
      `${process.env.GITHUB_SHA}:${process.env.GITHUB_RUN_ID}:${process.env.GITHUB_RUN_ATTEMPT}:${targetProject}`,
    )
    .digest("hex");
  transformed.application_release.rollout = {
    candidate_tag: `c-${seed.slice(24, 40)}`,
    phase: "active",
  };
  transformed.application_release.authentication.revision = `agora-authentication-rest-${seed.slice(0, 12)}`;
  transformed.application_release.authentication.active_revision =
    transformed.application_release.authentication.revision;
  transformed.application_release.authentication.secrets.postgres_password_version =
    receipt.database.authenticationPasswordVersion;
  transformed.application_release.json_keys.secrets.postgres_password_version =
    receipt.database.jsonKeysPasswordVersion;
  transformed.application_release.json_keys.revision = `agora-json-keys-grpc-${seed.slice(12, 24)}`;
  transformed.application_release.json_keys.active_revision =
    transformed.application_release.json_keys.revision;

  const staging = structuredClone(transformed);
  staging.application_release = null;

  const sourceImages = [
    receipt.database.authenticationImage,
    receipt.database.jsonKeysImage,
    ...Object.values(sourceTfvars.application_release.authentication.images),
    ...Object.values(sourceTfvars.application_release.json_keys.images),
  ];
  const images = [...new Set(sourceImages)].map((source) => {
    const target = replaceProjectInImage(
      source,
      region,
      sourceProject,
      targetProject,
    );
    return {
      source,
      target,
      tag: target.replace(
        /@sha256:[a-f0-9]{64}$/,
        `:recovery-${process.env.GITHUB_RUN_ID}`,
      ),
      digest: source.slice(source.indexOf("@") + 1),
    };
  });
  if (images.length !== 8)
    fail("selected receipt does not contain eight images");

  const database = {
    ...receipt.database,
    authenticationImage: transformed.database_releases.authentication.image,
    jsonKeysImage: transformed.database_releases.json_keys.image,
    releaseRevision: process.env.GITHUB_SHA,
  };
  const versions = sourceTfvars.application_release;
  const preflight = {
    schemaVersion: 1,
    cloud: {
      managementProjectId: sourceTfvars.management_project_id,
      workloadProjectId: targetProject,
      region,
      quotaExpectations: {
        cloud_run_cpu_millicpu:
          recoveryFoundation.cloud_run_cpu_quota_millicpu ?? 8000,
        cloud_run_memory_bytes:
          recoveryFoundation.cloud_run_memory_quota_bytes ?? 17179869184,
        compute_cpu: recoveryFoundation.compute_cpu_quota ?? 4,
      },
      secretVersions: [
        [
          "production-authentication-postgres-password",
          receipt.database.authenticationPasswordVersion,
        ],
        [
          "production-authentication-postgres-backup-password",
          receipt.database.authenticationBackupPasswordVersion,
        ],
        [
          "production-authentication-smtp-sender-password",
          versions.authentication.secrets.smtp_password_version,
        ],
        [
          "production-authentication-super-admin-password",
          versions.authentication.secrets.super_admin_password_version,
        ],
        [
          "production-json-keys-app-master-key",
          versions.json_keys.secrets.app_master_key_version,
        ],
        [
          "production-json-keys-postgres-password",
          receipt.database.jsonKeysPasswordVersion,
        ],
        [
          "production-json-keys-postgres-backup-password",
          receipt.database.jsonKeysBackupPasswordVersion,
        ],
      ],
    },
  };

  await Promise.all([
    writePrivate(path.join(outputDirectory, "staging.tfvars.json"), staging),
    writePrivate(path.join(outputDirectory, "active.tfvars.json"), transformed),
    writePrivate(path.join(outputDirectory, "images.json"), images),
    writePrivate(path.join(outputDirectory, "database.json"), database),
    writePrivate(path.join(outputDirectory, "preflight.json"), preflight),
  ]);
}

main().catch((error) => {
  process.stderr.write(`Recovery compilation failed: ${error.message}\n`);
  process.exitCode = 1;
});

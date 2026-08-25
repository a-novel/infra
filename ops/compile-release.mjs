#!/usr/bin/env node

/**
 * Compile the reviewed public image manifest and protected, non-payload
 * production configuration into exact OpenTofu inputs and rollback material.
 * Generated files are private workflow scratch data and must never be uploaded
 * as GitHub artifacts or printed to the log.
 */

import { createHash, randomBytes } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import { parse } from "yaml";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");

const requiredConfigKeys = [
  "management_project_id",
  "workload_project_id",
  "region",
  "database_zone",
  "backup_bucket_name",
  "database_private_ip",
  "network_id",
  "subnet_id",
  "authentication_initializer_principals",
  "authentication",
  "quota_expectations",
  "secret_versions",
];

const requiredSecretVersions = [
  "authentication_postgres_password",
  "authentication_postgres_backup_password",
  "authentication_postgres_dsn",
  "authentication_smtp_password",
  "authentication_super_admin_password",
  "json_keys_postgres_password",
  "json_keys_postgres_backup_password",
  "json_keys_postgres_dsn",
  "json_keys_app_master_key",
];

function fail(message) {
  throw new Error(message);
}

function exactKeys(value, expected, label) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    JSON.stringify(Object.keys(value).sort()) !==
      JSON.stringify([...expected].sort())
  ) {
    fail(`${label} has an unexpected shape`);
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function validateConfig(config) {
  exactKeys(config, requiredConfigKeys, "release configuration");
  exactKeys(
    config.secret_versions,
    requiredSecretVersions,
    "secret-version configuration",
  );

  for (const key of requiredSecretVersions) {
    if (
      !Number.isInteger(config.secret_versions[key]) ||
      config.secret_versions[key] < 1
    ) {
      fail(`secret_versions.${key} must be a positive integer`);
    }
  }

  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(config.workload_project_id)) {
    fail("workload_project_id is invalid");
  }
  if (!/^[a-z]+-[a-z]+[0-9]+$/.test(config.region)) {
    fail("region is invalid");
  }
  if (config.database_zone.slice(0, -2) !== config.region) {
    fail("database_zone must belong to region");
  }
  if (
    !Array.isArray(config.authentication_initializer_principals) ||
    config.authentication_initializer_principals.length === 0
  ) {
    fail("at least one Authentication initializer principal is required");
  }
  exactKeys(
    config.quota_expectations,
    [
      "cloud_run_cpu_millicpu",
      "cloud_run_memory_bytes",
      "cloud_run_direct_vpc_instances",
      "compute_cpu",
    ],
    "quota expectations",
  );
  if (
    !Object.values(config.quota_expectations).every(
      (value) => Number.isInteger(value) && value > 0,
    )
  ) {
    fail("quota expectations must be positive integers");
  }
}

function validateFamilyVersions(manifest) {
  for (const [component, definition] of Object.entries(manifest.components)) {
    if (!definition.enabled) {
      fail(`${component} must be enabled for a production release`);
    }
    const versions = new Set(
      Object.values(definition.images).map((image) => image.tag),
    );
    if (versions.size !== 1) {
      fail(`${component} images must use one SemVer release`);
    }
  }
}

function runtimeServiceAccounts(project) {
  return {
    authentication: `agora-authentication@${project}.iam.gserviceaccount.com`,
    authentication_initializer: `agora-auth-initializer@${project}.iam.gserviceaccount.com`,
    backup: `agora-backup@${project}.iam.gserviceaccount.com`,
    json_keys: `agora-json-keys@${project}.iam.gserviceaccount.com`,
    restore: `agora-restore@${project}.iam.gserviceaccount.com`,
    scheduler_invoker: `agora-scheduler-invoker@${project}.iam.gserviceaccount.com`,
  };
}

function buildBaseTfvars(config) {
  return {
    management_project_id: config.management_project_id,
    workload_project_id: config.workload_project_id,
    region: config.region,
    backup_bucket_name: config.backup_bucket_name,
    database_private_ip: config.database_private_ip,
    network_id: config.network_id,
    subnet_id: config.subnet_id,
    runtime_service_accounts: runtimeServiceAccounts(
      config.workload_project_id,
    ),
    authentication_initializer_principals:
      config.authentication_initializer_principals,
  };
}

function promotedImage(config, image) {
  const suffix = image.repository.replace("ghcr.io/a-novel/", "");
  return `${config.region}-docker.pkg.dev/${config.workload_project_id}/agora-production/${suffix}@${image.digest}`;
}

function normalizeImages(config, manifest) {
  const images = [];
  for (const [component, definition] of Object.entries(manifest.components)) {
    for (const [slot, image] of Object.entries(definition.images)) {
      const promoted = promotedImage(config, image);
      images.push({
        component,
        slot,
        repository: image.repository,
        tag: image.tag,
        digest: image.digest,
        source: `${image.repository}:${image.tag}`,
        sourceDigest: `${image.repository}@${image.digest}`,
        promoted,
        promotedTag: promoted.replace(`@${image.digest}`, `:${image.tag}`),
      });
    }
  }
  return images;
}

function imageAt(images, component, slot) {
  const image = images.find(
    (candidate) => candidate.component === component && candidate.slot === slot,
  );
  if (!image) fail(`missing image ${component}/${slot}`);
  return image.promoted;
}

function applicationRelease(
  config,
  images,
  rollout,
  revisions,
  activeRevisions,
) {
  const versions = config.secret_versions;
  return {
    rollout: { candidate_tag: rollout.candidateTag, phase: rollout.phase },
    authentication: {
      ...(activeRevisions.authentication
        ? { active_revision: activeRevisions.authentication }
        : {}),
      images: {
        init: imageAt(images, "service-authentication", "jobs/init"),
        migrations: imageAt(
          images,
          "service-authentication",
          "jobs/migrations",
        ),
        rest: imageAt(images, "service-authentication", "rest"),
      },
      revision: revisions.authentication,
      secrets: {
        postgres_dsn_version: versions.authentication_postgres_dsn,
        smtp_password_version: versions.authentication_smtp_password,
        super_admin_password_version:
          versions.authentication_super_admin_password,
      },
      smtp: config.authentication.smtp,
      super_admin_email: config.authentication.super_admin_email,
    },
    json_keys: {
      ...(activeRevisions.jsonKeys
        ? { active_revision: activeRevisions.jsonKeys }
        : {}),
      images: {
        grpc: imageAt(images, "service-json-keys", "grpc"),
        migrations: imageAt(images, "service-json-keys", "jobs/migrations"),
        rotate_keys: imageAt(images, "service-json-keys", "jobs/rotatekeys"),
      },
      revision: revisions.jsonKeys,
      secrets: {
        app_master_key_version: versions.json_keys_app_master_key,
        postgres_dsn_version: versions.json_keys_postgres_dsn,
      },
    },
  };
}

async function loadJson(file, label) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch {
    fail(`${label} is not valid JSON`);
  }
}

async function writePrivateJson(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await chmod(file, 0o600);
}

export async function compileRelease({
  manifestPath,
  configPath,
  previousReceiptPath = null,
  outputDirectory,
  commit,
  runId,
  runAttempt,
  nonce,
  action = "deploy",
}) {
  if (!new Set(["deploy", "rollback"]).has(action)) {
    fail("release action is invalid");
  }
  if (!/^[a-f0-9]{40}$/.test(commit)) fail("release commit is invalid");
  if (!/^[1-9][0-9]*$/.test(runId)) fail("GitHub run ID is invalid");
  if (!Number.isInteger(runAttempt) || runAttempt < 1) {
    fail("GitHub run attempt is invalid");
  }

  const manifestText = await readFile(manifestPath, "utf8");
  const manifest = parse(manifestText);
  const manifestSchema = await loadJson(
    path.join(repositoryRoot, "deploy/production/images.schema.json"),
    "image manifest schema",
  );
  const receiptSchema = await loadJson(
    path.join(repositoryRoot, "deploy/production/receipt.schema.json"),
    "receipt schema",
  );
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  if (!ajv.compile(manifestSchema)(manifest)) {
    fail("the production image manifest is invalid");
  }
  validateFamilyVersions(manifest);

  const config = await loadJson(configPath, "release configuration");
  validateConfig(config);

  let previousReceipt = null;
  if (previousReceiptPath) {
    previousReceipt = await loadJson(
      previousReceiptPath,
      "previous release receipt",
    );
    if (!ajv.compile(receiptSchema)(previousReceipt)) {
      fail("the previous release receipt is invalid");
    }
  }
  if (action === "rollback" && previousReceipt === null) {
    fail("rollback requires an exact prior release receipt");
  }

  const seed = sha256(`${commit}:${runId}:${runAttempt}:${nonce}`);
  const revisions = {
    authentication: `agora-authentication-rest-${seed.slice(0, 12)}`,
    jsonKeys: `agora-json-keys-grpc-${seed.slice(12, 24)}`,
  };
  const candidateTag = `c-${sha256(`${seed}:candidate`).slice(0, 32)}`;
  const images = normalizeImages(config, manifest);
  const baseTfvars = buildBaseTfvars(config);
  const previousActive = previousReceipt?.activeTfvars?.application_release;
  const previousRevisions = {
    authentication: previousActive?.authentication?.active_revision ?? null,
    jsonKeys: previousActive?.json_keys?.active_revision ?? null,
  };
  const databaseConfiguration = {
    jsonKeysImage: imageAt(images, "service-json-keys", "database"),
    authenticationImage: imageAt(images, "service-authentication", "database"),
    jsonKeysPasswordVersion: config.secret_versions.json_keys_postgres_password,
    authenticationPasswordVersion:
      config.secret_versions.authentication_postgres_password,
    jsonKeysBackupPasswordVersion:
      config.secret_versions.json_keys_postgres_backup_password,
    authenticationBackupPasswordVersion:
      config.secret_versions.authentication_postgres_backup_password,
  };
  const previousDatabase = previousReceipt?.database;
  const databaseUnchanged =
    previousDatabase !== null &&
    previousDatabase !== undefined &&
    Object.entries(databaseConfiguration).every(
      ([key, value]) => previousDatabase[key] === value,
    );
  const database = {
    releaseRevision: databaseUnchanged
      ? previousDatabase.releaseRevision
      : commit,
    ...databaseConfiguration,
  };
  const databaseReleases = {
    authentication: {
      image: database.authenticationImage,
      backup_password_version: database.authenticationBackupPasswordVersion,
    },
    json_keys: {
      image: database.jsonKeysImage,
      backup_password_version: database.jsonKeysBackupPasswordVersion,
    },
  };

  const candidateTfvars = {
    ...baseTfvars,
    database_releases: databaseReleases,
    application_release: applicationRelease(
      config,
      images,
      { candidateTag, phase: "candidate" },
      revisions,
      previousRevisions,
    ),
  };
  const activeTfvars = {
    ...baseTfvars,
    database_releases: databaseReleases,
    application_release: applicationRelease(
      config,
      images,
      { candidateTag, phase: "active" },
      revisions,
      revisions,
    ),
  };
  let rollbackTfvars;
  if (previousActive) {
    rollbackTfvars = structuredClone(previousReceipt.activeTfvars);
    // Cloud Run revisions are immutable and explicit revision names cannot be
    // reused. Recreate the previous templates under fresh rollback names while
    // routing 100% of traffic to the receipt-owned prior active revisions.
    rollbackTfvars.application_release.rollout = {
      candidate_tag: candidateTag,
      phase: "active",
    };
    rollbackTfvars.application_release.authentication.revision = `agora-authentication-rest-${sha256(`${seed}:rollback-auth`).slice(0, 12)}`;
    rollbackTfvars.application_release.json_keys.revision = `agora-json-keys-grpc-${sha256(`${seed}:rollback-json`).slice(0, 12)}`;
  } else {
    // A failed first deployment records successful compensation with no active
    // application. Preserve that empty state as the next rollback target.
    rollbackTfvars = {
      ...baseTfvars,
      database_releases: {},
      application_release: null,
    };
  }

  let checkedSecretVersions = [
    [
      "production-authentication-postgres-dsn",
      config.secret_versions.authentication_postgres_dsn,
    ],
    [
      "production-authentication-postgres-password",
      config.secret_versions.authentication_postgres_password,
    ],
    [
      "production-authentication-postgres-backup-password",
      config.secret_versions.authentication_postgres_backup_password,
    ],
    [
      "production-authentication-smtp-sender-password",
      config.secret_versions.authentication_smtp_password,
    ],
    [
      "production-authentication-super-admin-password",
      config.secret_versions.authentication_super_admin_password,
    ],
    [
      "production-json-keys-app-master-key",
      config.secret_versions.json_keys_app_master_key,
    ],
    [
      "production-json-keys-postgres-dsn",
      config.secret_versions.json_keys_postgres_dsn,
    ],
    [
      "production-json-keys-postgres-password",
      config.secret_versions.json_keys_postgres_password,
    ],
    [
      "production-json-keys-postgres-backup-password",
      config.secret_versions.json_keys_postgres_backup_password,
    ],
  ];
  if (action === "rollback") {
    const targetApplication = rollbackTfvars.application_release;
    const targetDatabase = previousReceipt.database;
    checkedSecretVersions = targetApplication
      ? [
          [
            "production-authentication-postgres-dsn",
            targetApplication.authentication.secrets.postgres_dsn_version,
          ],
          [
            "production-authentication-postgres-password",
            targetDatabase.authenticationPasswordVersion,
          ],
          [
            "production-authentication-postgres-backup-password",
            targetDatabase.authenticationBackupPasswordVersion,
          ],
          [
            "production-authentication-smtp-sender-password",
            targetApplication.authentication.secrets.smtp_password_version,
          ],
          [
            "production-authentication-super-admin-password",
            targetApplication.authentication.secrets
              .super_admin_password_version,
          ],
          [
            "production-json-keys-app-master-key",
            targetApplication.json_keys.secrets.app_master_key_version,
          ],
          [
            "production-json-keys-postgres-dsn",
            targetApplication.json_keys.secrets.postgres_dsn_version,
          ],
          [
            "production-json-keys-postgres-password",
            targetDatabase.jsonKeysPasswordVersion,
          ],
          [
            "production-json-keys-postgres-backup-password",
            targetDatabase.jsonKeysBackupPasswordVersion,
          ],
        ]
      : [];
  }

  const release = {
    schemaVersion: 1,
    action,
    commit,
    runId,
    runAttempt,
    manifestSha256: sha256(manifestText),
    postgresMajor: manifest.postgresMajor,
    cloud: {
      managementProjectId: config.management_project_id,
      workloadProjectId: config.workload_project_id,
      region: config.region,
      databaseZone: config.database_zone,
      quotaExpectations: config.quota_expectations,
      secretVersions: checkedSecretVersions,
    },
    candidateTag,
    revisions,
    images,
    database,
    previousDatabase: previousReceipt?.database ?? null,
  };

  await mkdir(outputDirectory, { recursive: true, mode: 0o700 });
  await chmod(outputDirectory, 0o700);
  await Promise.all([
    writePrivateJson(path.join(outputDirectory, "release.json"), release),
    writePrivateJson(
      path.join(outputDirectory, "candidate.tfvars.json"),
      candidateTfvars,
    ),
    writePrivateJson(
      path.join(outputDirectory, "active.tfvars.json"),
      activeTfvars,
    ),
    writePrivateJson(
      path.join(outputDirectory, "rollback.tfvars.json"),
      rollbackTfvars,
    ),
  ]);

  return { release, candidateTfvars, activeTfvars, rollbackTfvars };
}

async function main() {
  if (process.argv.length !== 6) {
    fail(
      "usage: compile-release.mjs <manifest> <config> <previous-receipt-or-> <output-directory>",
    );
  }
  const [, , manifestPath, configPath, receiptArgument, outputDirectory] =
    process.argv;
  await compileRelease({
    manifestPath,
    configPath,
    previousReceiptPath: receiptArgument === "-" ? null : receiptArgument,
    outputDirectory,
    commit: process.env.GITHUB_SHA ?? "",
    runId: process.env.GITHUB_RUN_ID ?? "",
    runAttempt: Number(process.env.GITHUB_RUN_ATTEMPT ?? ""),
    nonce: randomBytes(16).toString("hex"),
    action: process.env.RELEASE_ACTION ?? "deploy",
  });
  process.stdout.write(
    "Release inputs compiled in private workflow storage.\n",
  );
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    process.stderr.write(`Release compilation failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}

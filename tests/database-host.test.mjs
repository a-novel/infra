import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import {
  chmod,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { fileURLToPath } from "node:url";

const execFile = promisify(execFileCallback);
const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const script = path.join(repositoryRoot, "ops/database-host.sh");

test("database host SSH setup is repeatable and derives the live host", async (context) => {
  const temporaryDirectory = await mkdtemp(
    path.join(os.tmpdir(), "infra-database-host-"),
  );
  context.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const binaryDirectory = path.join(temporaryDirectory, "bin");
  const keyFile = path.join(temporaryDirectory, ".ssh", "a-novel-gcp-ed25519");
  const halfKeyFile = path.join(temporaryDirectory, "half-key");
  const gcloudLog = path.join(temporaryDirectory, "gcloud.log");
  const keygenLog = path.join(temporaryDirectory, "keygen.log");
  await mkdir(binaryDirectory);
  await writeFile(gcloudLog, "");
  await writeFile(keygenLog, "");

  const fakeGcloud = `#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_GCLOUD_LOG"
case "$*" in
  "compute os-login ssh-keys describe "*"--format=value(fingerprint)")
    printf '%s\\n' 'SHA256:fixture-fingerprint'
    ;;
  "compute os-login ssh-keys describe "*)
    [ "\${FAKE_KEY_EXISTS:-false}" = true ]
    ;;
  "compute os-login ssh-keys add "*|"compute os-login ssh-keys update "*)
    ;;
  "compute instance-groups managed list "*)
    printf '%s\\n' 'europe-west1-d'
    ;;
  "compute instance-groups managed list-instances "*)
    printf '%s\\n' 'agora-database-test'
    ;;
  "compute instances describe "*"--format=value(networkInterfaces[0].networkIP)")
    printf '%s\\n' '10.20.0.2'
    ;;
  "compute ssh "*)
    ;;
  *)
    printf 'Unexpected gcloud call: %s\\n' "$*" >&2
    exit 64
    ;;
esac
`;
  const fakeKeygen = `#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_KEYGEN_LOG"
key_file=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ]; then
    key_file="$2"
    break
  fi
  shift
done
[ -n "$key_file" ]
printf '%s\\n' 'fixture-private-key' >"$key_file"
printf '%s\\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture a-novel-database-operator' >"\${key_file}.pub"
`;

  await writeFile(path.join(binaryDirectory, "gcloud"), fakeGcloud);
  await writeFile(path.join(binaryDirectory, "ssh-keygen"), fakeKeygen);
  await chmod(path.join(binaryDirectory, "gcloud"), 0o700);
  await chmod(path.join(binaryDirectory, "ssh-keygen"), 0o700);

  const baseEnvironment = {
    ...process.env,
    PATH: `${binaryDirectory}:${process.env.PATH}`,
    FAKE_GCLOUD_LOG: gcloudLog,
    FAKE_KEYGEN_LOG: keygenLog,
    INFRA_MANAGEMENT_PROJECT_ID: "management-project-prod",
    INFRA_WORKLOAD_PROJECT_ID: "workload-project-prod",
    HOME: temporaryDirectory,
  };

  await assert.rejects(
    execFile(script, ["inspect", "--ttl", "2h"], { env: baseEnvironment }),
    (error) => error.code === 64,
  );

  const created = await execFile(script, ["key"], {
    env: baseEnvironment,
  });
  assert.equal(
    created.stdout.trim(),
    "PASS OS Login SSH key SHA256:fixture-fingerprint",
  );
  assert.match(
    await readFile(path.join(`${keyFile}.pub`), "utf8"),
    /^ssh-ed25519 /,
  );
  assert.match(await readFile(keygenLog, "utf8"), /-t ed25519 -a 64/);
  assert.match(
    await readFile(gcloudLog, "utf8"),
    /compute os-login ssh-keys add .*--ttl=1h/,
  );

  await writeFile(gcloudLog, "");
  const renewed = await execFile(
    script,
    ["key", "--key-file", keyFile, "--ttl", "2h"],
    { env: { ...baseEnvironment, FAKE_KEY_EXISTS: "true" } },
  );
  assert.equal(
    renewed.stdout.trim(),
    "PASS OS Login SSH key SHA256:fixture-fingerprint",
  );
  assert.match(
    await readFile(gcloudLog, "utf8"),
    /compute os-login ssh-keys update .*--ttl=2h/,
  );
  assert.equal(
    (await readFile(keygenLog, "utf8")).trim().split("\n").length,
    1,
  );

  await writeFile(halfKeyFile, "fixture-private-key\n");
  await assert.rejects(
    execFile(script, ["key", "--key-file", halfKeyFile], {
      env: baseEnvironment,
    }),
    (error) =>
      error.code === 64 &&
      error.stderr.includes("SSH private and public key files must both exist"),
  );

  await writeFile(gcloudLog, "");
  await execFile(script, ["ssh", "--key-file", keyFile], {
    env: { ...baseEnvironment, FAKE_KEY_EXISTS: "true" },
  });
  const sshLog = await readFile(gcloudLog, "utf8");
  assert.match(
    sshLog,
    /compute instance-groups managed list --project=workload-project-prod --filter=name=agora-database/,
  );
  assert.match(
    sshLog,
    new RegExp(
      `compute ssh agora-database-test --project=workload-project-prod --zone=europe-west1-d --ssh-key-file=${keyFile} --ssh-key-expire-after=1h --tunnel-through-iap`,
    ),
  );

  await writeFile(gcloudLog, "");
  await execFile(script, ["troubleshoot", "--key-file", keyFile], {
    env: { ...baseEnvironment, FAKE_KEY_EXISTS: "true" },
  });
  assert.match(
    await readFile(gcloudLog, "utf8"),
    /compute ssh .*--tunnel-through-iap --troubleshoot/,
  );
});

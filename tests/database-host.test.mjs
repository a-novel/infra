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

test("database host access is repeatable and derives the live host", async (context) => {
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
  "compute instance-groups managed list "*)
    printf '%s\\n' 'europe-west1-d'
    ;;
  "compute instance-groups managed list-instances "*)
    printf '%s\\n' 'agora-database-test'
    ;;
  "compute instances describe "*"--format=value(networkInterfaces[0].networkIP)")
    printf '%s\\n' '10.20.0.2'
    ;;
  "compute instance-groups managed describe "*|"compute instances describe "*|"compute disks describe "*|"compute resource-policies describe "*|"compute snapshots list "*|"compute firewall-rules describe "*|"monitoring policies list "*)
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

  const localEnvironment = {
    ...process.env,
    PATH: `${binaryDirectory}:${process.env.PATH}`,
    FAKE_GCLOUD_LOG: gcloudLog,
    FAKE_KEYGEN_LOG: keygenLog,
    HOME: temporaryDirectory,
  };
  const cloudEnvironment = {
    ...localEnvironment,
    INFRA_MANAGEMENT_PROJECT_ID: "management-project-prod",
    INFRA_WORKLOAD_PROJECT_ID: "workload-project-prod",
  };

  await assert.rejects(
    execFile(script, ["inspect", "--ttl", "2h"], { env: cloudEnvironment }),
    (error) => error.code === 64,
  );
  await assert.rejects(
    execFile(script, ["key", "--ttl", "2h"], { env: localEnvironment }),
    (error) => error.code === 64,
  );

  const created = await execFile(script, ["key"], {
    env: localEnvironment,
  });
  assert.equal(created.stdout.trim(), "PASS local SSH key pair");
  assert.match(
    await readFile(path.join(`${keyFile}.pub`), "utf8"),
    /^ssh-ed25519 /,
  );
  assert.match(await readFile(keygenLog, "utf8"), /-t ed25519 -a 64/);
  assert.equal(await readFile(gcloudLog, "utf8"), "");

  const reused = await execFile(script, ["key", "--key-file", keyFile], {
    env: localEnvironment,
  });
  assert.equal(reused.stdout.trim(), "PASS local SSH key pair");
  assert.equal(await readFile(gcloudLog, "utf8"), "");
  assert.equal(
    (await readFile(keygenLog, "utf8")).trim().split("\n").length,
    1,
  );

  await writeFile(halfKeyFile, "fixture-private-key\n");
  await assert.rejects(
    execFile(script, ["key", "--key-file", halfKeyFile], {
      env: localEnvironment,
    }),
    (error) =>
      error.code === 64 &&
      error.stderr.includes("SSH private and public key files must both exist"),
  );

  await writeFile(gcloudLog, "");
  await execFile(script, ["ssh", "--key-file", keyFile, "--ttl", "2h"], {
    env: cloudEnvironment,
  });
  const sshLog = await readFile(gcloudLog, "utf8");
  assert.match(
    sshLog,
    /compute instance-groups managed list --project=workload-project-prod --filter=name=agora-database/,
  );
  assert.match(
    sshLog,
    new RegExp(
      `compute ssh agora-database-test --project=workload-project-prod --zone=europe-west1-d --ssh-key-file=${keyFile} --ssh-key-expire-after=2h --tunnel-through-iap`,
    ),
  );
  assert.doesNotMatch(sshLog, /compute os-login/);

  await writeFile(gcloudLog, "");
  await execFile(script, ["troubleshoot", "--key-file", keyFile], {
    env: cloudEnvironment,
  });
  assert.match(
    await readFile(gcloudLog, "utf8"),
    /compute ssh .*--tunnel-through-iap --troubleshoot/,
  );

  await writeFile(gcloudLog, "");
  const inspected = await execFile(script, ["inspect"], {
    env: cloudEnvironment,
  });
  assert.match(inspected.stdout, /PASS database host inspection\n$/);
  const inspectionLog = await readFile(gcloudLog, "utf8");
  assert.doesNotMatch(
    inspectionLog,
    /get-iam-policy|config get-value account|compute os-login/,
  );
});

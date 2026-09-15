import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";
import { compileRelease } from "../ops/compile-release.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const revision = "b".repeat(40);
const original = "a".repeat(40);
const configPath = path.join(root, "tests/fixtures/release-config.json");
const config = JSON.parse(await readFile(configPath, "utf8"));

async function fixture(t, scenario = "success") {
  const dir = await mkdtemp(path.join(os.tmpdir(), "infra-isolation-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(path.join(dir, "ops"));
  await mkdir(path.join(dir, "bin"));
  await mkdir(path.join(dir, "deploy/production"), { recursive: true });
  const manifestPath = path.join(dir, "deploy/production/images.yaml");
  await copyFile(
    path.join(root, "tests/fixtures/manifests/valid.yaml"),
    manifestPath,
  );
  const first = await compileRelease({
    manifestPath,
    configPath,
    outputDirectory: path.join(dir, "first"),
    commit: original,
    runId: "123",
    runAttempt: 1,
  });
  const receipt = {
    schemaVersion: 1,
    kind: "deployment",
    createdAt: "2026-09-15T00:00:00Z",
    sequence: { runId: "123", runAttempt: 1 },
    source: { commit: original, manifestSha256: first.release.manifestSha256 },
    activeTfvars: first.activeTfvars,
    database: first.release.database,
    imageManifest: first.release.imageManifest,
    operations: {
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
    },
  };
  const receiptFile = path.join(dir, "receipt.json");
  await writeFile(receiptFile, JSON.stringify(receipt));
  for (const file of [
    "drill-database-isolation.sh",
    "receipt-custody.sh",
    "prepare-database-change.sh",
    "deploy-database-release.sh",
    "restore-database-release.sh",
    "database-host-readiness.sh",
    "preflight-release.sh",
  ]) {
    await copyFile(path.join(root, "ops", file), path.join(dir, "ops", file));
    await chmod(path.join(dir, "ops", file), 0o700);
  }
  for (const file of ["compile-release.mjs", "validate-receipt.mjs"])
    await writeFile(
      path.join(dir, "ops", file),
      `#!/bin/bash\nexec '${path.join(root, "ops", file)}' "$@"\n`,
      { mode: 0o700 },
    );

  const state = {
    config,
    scenario,
    calls: [],
    restarts: 0,
    inventories: 0,
    hosts: {},
  };
  for (const [service, key, prefix] of [
    ["authentication", "authentication", "authentication"],
    ["json-keys", "json_keys", "jsonKeys"],
  ]) {
    const host = config.database_hosts[key];
    const disk = `https://www.googleapis.com/compute/v1/projects/${config.workload_project_id}/zones/${config.database_zone}/disks/agora-data-${service}`;
    state.hosts[service] = {
      metadata: {
        "agora-database-release-revision": original,
        [`agora-${service}-database-image`]: receipt.database[`${prefix}Image`],
        [`agora-${service}-postgres-password-version`]: "1",
        [`agora-${service}-postgres-backup-password-version`]: "1",
      },
      diskId: host.data_disk_id,
      vm: {
        name: `agora-database-${service}-test`,
        id: host.data_disk_id,
        status: "RUNNING",
        lastStartTimestamp: "2026-09-14T12:00:00Z",
        networkInterfaces: [
          {
            network: "private",
            subnetwork: "private",
            networkIP: host.private_ip,
          },
        ],
        disks: [
          {
            source: disk,
            deviceName: "agora-data",
            boot: false,
            autoDelete: false,
          },
        ],
      },
      guest: `healthy:${original}:00000000-0000-4000-8000-000000000000`,
    };
  }
  if (scenario === "metadata-drift")
    state.hosts.authentication.metadata.unexpected = "refuse";
  if (scenario === "wrong-disk") state.hosts.authentication.diskId = "99";
  if (scenario === "wrong-peer-ip")
    state.hosts["json-keys"].vm.networkInterfaces[0].networkIP = "10.20.0.99";
  if (scenario === "interrupted") {
    state.hosts.authentication.metadata["agora-database-release-revision"] =
      revision;
    state.hosts.authentication.guest = `failed:${revision}:00000000-0000-4000-8000-000000000001`;
  }
  const stateFile = path.join(dir, "cloud.json");
  await writeFile(stateFile, JSON.stringify(state));
  // The real repository helpers execute against one strict, credential-free cloud stub.
  const fakeCloud = `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2), joined = args.join(' ');
const file = process.env.FAKE_CLOUD, state = JSON.parse(fs.readFileSync(file));
state.calls.push(args);
function save() { fs.writeFileSync(file, JSON.stringify(state)); }
function out(value) { save(); process.stdout.write(typeof value === 'string' ? value + '\\n' : JSON.stringify(value)); }
function fail() { save(); process.exit(1); }
const service = joined.includes('agora-database-json-keys') || joined.includes('agora-data-json-keys') ? 'json-keys' : 'authentication';
const host = state.hosts[service];
if (joined.startsWith('storage objects list ')) {
  state.inventories++;
  out('production/success/00000000000000000123-00001.json');
} else if (joined.startsWith('storage cp ')) {
  let receipt = JSON.parse(fs.readFileSync(process.env.FAKE_RECEIPT));
  if (state.scenario === 'new-receipt' && state.inventories > 1) receipt.sequence.runId = '124';
  fs.writeFileSync(args[3], JSON.stringify(receipt)); save();
} else if (joined.startsWith('secrets versions describe ')) {
  out(state.scenario === 'disabled-secret' ? 'DISABLED' : 'ENABLED');
} else if (joined.startsWith('quotas preferences list ')) {
  out(Object.entries(state.config.quota_expectations).map(([key, value]) => ({ dimensions: {region: state.config.region}, service: key === 'compute_cpu' ? 'compute.googleapis.com' : 'run.googleapis.com', quotaConfig: {preferredValue: value, grantedValue: value} })));
} else if (joined.startsWith('compute instance-groups managed describe ')) {
  out({targetSize: 1, status: {isStable: true, versionTarget: {isReached: state.scenario !== 'pending-template'}, allInstancesConfig: {effective: true}}, updatePolicy: {type: 'OPPORTUNISTIC'}, statefulPolicy: {preservedState: {disks: {'agora-data': {autoDelete: 'NEVER'}}, internalIPs: {nic0: {autoDelete: 'NEVER'}}}}, instanceTemplate: 'fixed-template', versions: [{instanceTemplate: 'fixed-template'}], allInstancesConfig: {properties: {metadata: host.metadata}}});
} else if (joined.startsWith('compute instance-groups managed list-instances ')) {
  out(host.vm.name);
} else if (joined.startsWith('compute instances describe ')) {
  if (state.scenario === 'vm-read-denied') { process.stderr.write('PERMISSION_DENIED: compute.instances.get\\n'); fail(); }
  out(host.vm);
} else if (joined.startsWith('compute disks describe ')) {
  out(host.diskId);
} else if (joined.startsWith('compute instances get-guest-attributes ')) {
  out(host.guest);
} else if (joined.startsWith('compute snapshots list ')) {
  out([{name: 'daily', autoCreated: true, status: 'READY', sourceDisk: host.vm.disks[0].source, sourceDiskId: host.diskId, creationTimestamp: new Date(Date.now() - (state.scenario === 'stale-snapshot' ? 100000000 : 3600000)).toISOString(), storageLocations: ['europe-west1'], labels: {application: 'agora', environment: 'production', component: service, 'managed-by': 'opentofu', plane: 'workload', role: 'database-snapshot'}}]);
} else if (joined.startsWith('run jobs execute agora-postgres-backup-authentication ')) {
  if (state.scenario === 'backup-failure') fail();
  if (state.scenario === 'peer-during-preflight') state.hosts['json-keys'].vm.lastStartTimestamp = '2026-09-15T12:00:00Z';
  save();
} else if (joined.startsWith('compute instance-groups managed all-instances-config update ')) {
  if (service !== 'authentication') throw Error('peer mutation');
  host.metadata = Object.fromEntries(args.find(a => a.startsWith('--metadata=')).slice(11).split(',').map(s => [s.slice(0, s.indexOf('=')), s.slice(s.indexOf('=') + 1)]));
  if (state.scenario === 'external-image-drift') { host.metadata['agora-authentication-database-image'] += 'unexpected'; fail(); }
  if (state.scenario === 'external-revision-drift') { host.metadata['agora-database-release-revision'] = 'c'.repeat(40); fail(); }
  if (state.scenario === 'partial-write' && host.metadata['agora-database-release-revision'] !== '${original}') fail();
  if (state.scenario === 'rollback-failure' && host.metadata['agora-database-release-revision'] === '${original}') fail();
  save();
} else if (joined.startsWith('compute instance-groups managed update-instances ')) {
  if (service !== 'authentication' || !args.includes('--minimal-action=restart') || !args.includes('--most-disruptive-allowed-action=restart')) throw Error('unbounded mutation');
  state.restarts++;
  host.vm.lastStartTimestamp = '2026-09-15T12:00:0' + state.restarts + 'Z';
  host.guest = 'healthy:' + host.metadata['agora-database-release-revision'] + ':00000000-0000-4000-8000-00000000000' + state.restarts;
  if (state.scenario === 'failed-convergence' && state.restarts === 1) host.guest = host.guest.replace('healthy:', 'failed:');
  if ((state.scenario === 'peer-during-restart' && state.restarts === 1) || (state.scenario === 'peer-during-rollback' && state.restarts === 2)) state.hosts['json-keys'].vm.lastStartTimestamp = host.vm.lastStartTimestamp;
  if (state.scenario === 'auth-replaced' && state.restarts === 2) host.vm.id = '999';
  save();
} else if (joined.startsWith('compute instance-groups managed wait-until ')) {
  save();
} else { throw Error('Unexpected gcloud call: ' + joined); }
`;
  await writeFile(path.join(dir, "bin/gcloud"), fakeCloud, { mode: 0o700 });
  return {
    dir,
    stateFile,
    receiptFile,
    async run(
      operation = "drill",
      {
        target = "123-1",
        confirmation = `${operation.toUpperCase()} authentication`,
        environment = {},
        extra = [],
      } = {},
    ) {
      const result = spawnSync(
        path.join(dir, "ops/drill-database-isolation.sh"),
        [operation, target, confirmation, configPath, ...extra],
        {
          timeout: 60000,
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: `${dir}/bin:${process.env.PATH}`,
            FAKE_CLOUD: stateFile,
            FAKE_RECEIPT: receiptFile,
            RECEIPT_BUCKET: "agora-test-receipts",
            GITHUB_SHA: revision,
            GITHUB_RUN_ID: "124",
            GITHUB_RUN_ATTEMPT: "1",
            GITHUB_REPOSITORY: "a-novel/infra",
            GITHUB_EVENT_NAME: "workflow_dispatch",
            GITHUB_WORKFLOW_REF:
              "a-novel/infra/.github/workflows/release.yaml@refs/heads/master",
            GITHUB_STEP_SUMMARY: path.join(dir, "summary.md"),
            ...environment,
          },
        },
      );
      assert.equal(result.error, undefined, result.error?.message);
      return {
        ...result,
        state: JSON.parse(await readFile(stateFile, "utf8")),
      };
    },
  };
}

function mutations(state) {
  return state.calls.filter(
    (args) => args.includes("update") || args.includes("update-instances"),
  );
}

test("denied VM inspection stops before backup, restart or compensation", async (t) => {
  const f = await fixture(t, "vm-read-denied");
  const result = await f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /PERMISSION_DENIED: compute\.instances\.get/);
  assert.deepEqual(mutations(result.state), []);
  assert.equal(result.state.restarts, 0);
  assert.equal(
    result.state.calls.filter((args) => args.includes("execute")).length,
    0,
  );
});

test("documented SQL probe feeds one noninteractive session through Docker stdin", async (t) => {
  const doc = await readFile(
    path.join(root, "docs/runbooks/operate-postgresql-host.md"),
    "utf8",
  );
  const probe = [...doc.matchAll(/```bash\n([\s\S]*?)\n```/g)]
    .map((match) => match[1])
    .find((body) => body.includes("\\watch"));
  assert.ok(probe);
  assert.ok(!probe.includes("\n"));
  const dir = await mkdtemp(path.join(os.tmpdir(), "infra-isolation-probe-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await writeFile(
    path.join(dir, "sudo"),
    `#!${process.execPath}\nconst fs = require('node:fs');\nprocess.stdout.write(JSON.stringify({args: process.argv.slice(2), input: fs.readFileSync(0, 'utf8')}));\n`,
    { mode: 0o700 },
  );
  const result = spawnSync("bash", ["-c", probe], {
    encoding: "utf8",
    timeout: 10000,
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
  });
  assert.equal(result.status, 0, result.stderr);
  const { args, input } = JSON.parse(result.stdout);
  assert.deepEqual(args, [
    "docker",
    "exec",
    "-i",
    "--user",
    "postgres",
    "agora-postgres-json-keys",
    "psql",
    "--no-psqlrc",
    "--no-password",
    "--set=ON_ERROR_STOP=on",
    "--username=agora_json_keys",
    "--dbname=agora_json_keys",
  ]);
  assert.equal(
    input,
    "SELECT pg_backend_pid() AS connection_pid, pg_postmaster_start_time() AT TIME ZONE 'UTC' AS database_started_utc, clock_timestamp() AT TIME ZONE 'UTC' AS checked_utc;\n\\watch interval=2 count=3600\n",
  );
});

test("drill reuses real preflight/restart/rollback helpers and leaves the peer intact", async (t) => {
  const f = await fixture(t);
  const before = JSON.parse(await readFile(f.stateFile, "utf8"));
  const result = await f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.state.restarts, 2);
  assert.deepEqual(result.state.hosts["json-keys"], before.hosts["json-keys"]);
  assert.deepEqual(
    result.state.hosts.authentication.metadata,
    before.hosts.authentication.metadata,
  );
  assert.equal(mutations(result.state).length, 4);
  assert.ok(
    mutations(result.state).every((args) =>
      args.includes("agora-database-authentication"),
    ),
  );
  assert.equal(
    result.state.calls.filter((args) => args.includes("execute")).length,
    1,
  );
  assert.doesNotMatch(
    result.stdout + result.stderr,
    /sha256:|postgres-password-version|smtp-login/,
  );
  assert.match(
    await readFile(path.join(f.dir, "summary.md"), "utf8"),
    /Authentication restored: true; JSON Keys host unchanged: true/,
  );
});

for (const [scenario, reason] of Object.entries({
  "metadata-drift": /Authentication differs from the healthy receipt/,
  "wrong-disk": /Authentication host is not stable/,
  "wrong-peer-ip": /JSON Keys host is not stable/,
  "pending-template": /Authentication host is not stable/,
  "disabled-secret": /numeric Secret Manager version is not enabled/,
  "stale-snapshot": /outside the 26-hour daily change window/,
  "backup-failure": /pre-change PostgreSQL backup failed/,
  "peer-during-preflight": /JSON Keys changed during preflight/,
  "new-receipt": /selected receipt changed during preflight/,
})) {
  test(`drill refuses ${scenario} before database mutation`, async (t) => {
    const f = await fixture(t, scenario);
    const result = await f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, reason);
    assert.deepEqual(mutations(result.state), []);
  });
}

for (const scenario of [
  "partial-write",
  "failed-convergence",
  "peer-during-restart",
  "peer-during-rollback",
  "auth-replaced",
  "rollback-failure",
]) {
  test(`drill compensates safely and remains failed after ${scenario}`, async (t) => {
    const f = await fixture(t, scenario);
    const result = await f.run();
    assert.notEqual(result.status, 0);
    const updates = mutations(result.state).filter((args) =>
      args.includes("update"),
    );
    assert.equal(updates.length, 2, result.stderr);
    assert.ok(
      updates[1].some((arg) =>
        arg.includes(`agora-database-release-revision=${original}`),
      ),
    );
    assert.doesNotMatch(
      await readFile(path.join(f.dir, "summary.md"), "utf8"),
      /Exit status: 0/,
    );
  });
}

test("restore-only recovers an interrupted revision without another drill or backup", async (t) => {
  const f = await fixture(t, "interrupted");
  const refused = await f.run();
  assert.notEqual(refused.status, 0);
  assert.deepEqual(mutations(refused.state), []);
  const result = await f.run("restore");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.state.restarts, 1);
  assert.equal(
    result.state.hosts.authentication.metadata[
      "agora-database-release-revision"
    ],
    original,
  );
  assert.equal(
    result.state.calls.filter((args) => args.includes("execute")).length,
    0,
  );
});

for (const scenario of ["external-image-drift", "external-revision-drift"]) {
  test(`cleanup preserves unexpected ${scenario} for investigation`, async (t) => {
    const f = await fixture(t, scenario);
    const result = await f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /restoration refuses unexpected live metadata/);
    assert.equal(mutations(result.state).length, 1);
    assert.equal(result.state.restarts, 0);
    assert.match(
      await readFile(path.join(f.dir, "summary.md"), "utf8"),
      /Authentication restored: false/,
    );
  });
}

test("restore-only refuses changed image metadata", async (t) => {
  const f = await fixture(t, "interrupted");
  const state = JSON.parse(await readFile(f.stateFile, "utf8"));
  state.hosts.authentication.metadata["agora-authentication-database-image"] +=
    "different";
  await writeFile(f.stateFile, JSON.stringify(state));
  const result = await f.run("restore");
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /Restore refuses image, credential, or metadata-shape drift/,
  );
  assert.deepEqual(mutations(result.state), []);
});

test("a moved master manifest blocks a drill but does not block receipt-only restoration", async (t) => {
  const f = await fixture(t);
  await writeFile(
    path.join(f.dir, "deploy/production/images.yaml"),
    "invalid: manifest\n",
  );
  const refused = await f.run();
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /Release compilation failed/);
  assert.deepEqual(mutations(refused.state), []);
  const result = await f.run("restore");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.state.restarts, 1);
});

test("the selected receipt and drill revision must match distinct approved states", async (t) => {
  for (const options of [
    { target: "122-1" },
    { environment: { GITHUB_SHA: original } },
  ]) {
    const f = await fixture(t);
    const result = await f.run("drill", options);
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /Select the latest successful|drill commit must differ/,
    );
    assert.deepEqual(mutations(result.state), []);
  }
});

test("invalid confirmations, arguments and workflow identity cannot contact the cloud", async (t) => {
  for (const options of [
    { confirmation: "DRILL json-keys" },
    { target: "../receipt" },
    { extra: ["surplus"] },
    { environment: { GITHUB_EVENT_NAME: "push" } },
    { environment: { GITHUB_WORKFLOW_REF: "untrusted" } },
  ]) {
    const f = await fixture(t);
    const result = await f.run("drill", options);
    assert.notEqual(result.status, 0);
    assert.deepEqual(result.state.calls, []);
  }
});

test("isolation job is manual, release-locked, and has no apply or SSH authority", async () => {
  const workflow = parse(
    await readFile(path.join(root, ".github/workflows/release.yaml"), "utf8"),
  );
  const job = workflow.jobs["database-isolation"];
  assert.equal(workflow.concurrency.group, "production-infrastructure");
  assert.equal(workflow.concurrency["cancel-in-progress"], false);
  assert.equal(job.environment, "production-release");
  assert.deepEqual(job.permissions, { contents: "read", "id-token": "write" });
  assert.match(job.if, /github.event_name == 'workflow_dispatch'/);
  assert.match(job.if, /refs\/heads\/master/);
  assert.match(
    workflow.jobs.release.if,
    /!endsWith\(inputs.action, '-database-isolation'\)/,
  );
  assert.doesNotMatch(
    JSON.stringify(job),
    /tofu|compute ssh|add-iam|receipt-custody.sh.*publish/,
  );
  const guard = job.steps.findIndex(
    (step) => step.name === "Validate the manual isolation request",
  );
  const auth = job.steps.findIndex(
    (step) => step.name === "Authenticate as the release boundary",
  );
  assert.ok(guard >= 0 && guard < auth);
  assert.match(job.steps[guard].run, /DRILL authentication/);
  assert.match(job.steps[guard].run, /RESTORE authentication/);
  assert.match(job.steps[guard].run, /commits\/master/);
  for (const step of job.steps.filter((step) => step.run))
    execFileSync("bash", ["-n"], { input: step.run });
});

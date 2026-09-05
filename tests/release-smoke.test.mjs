import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const healthy = {
  "api:jsonKeys": { status: "up" },
  "client:postgres": { status: "up" },
  "client:smtp": { status: "up" },
};

async function smoke(t, options = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "infra-smoke-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const commit = "a".repeat(40);
  await writeFile(
    path.join(directory, "release.json"),
    JSON.stringify({
      cloud: {
        workloadProjectId: "workload-test",
        region: "europe-west1",
        databaseZone: "europe-west1-d",
      },
      commit,
      runId: "123",
      runAttempt: 1,
      revisions: { authentication: "auth-candidate" },
      candidateTag: "candidate",
    }),
  );
  await writeFile(
    path.join(directory, "operations.json"),
    JSON.stringify({ health: { authentication: "not-run" } }),
  );
  await writeFile(
    path.join(directory, "gcloud"),
    `#!${process.execPath}
const args = process.argv.slice(2);
if (!args.includes('--project=workload-test') || !args.includes('--region=europe-west1')) process.exit(99);
if (args.slice(0, 3).join(' ') === 'run revisions describe') {
  process.stdout.write(JSON.stringify({ status: { conditions: [{ type: 'Ready', status: process.env.MOCK_READY }] } }));
} else if (args.slice(0, 4).join(' ') === 'run services describe agora-authentication-rest') {
  if (process.env.MOCK_LOOKUP_FAILURE === 'true') process.exit(1);
  process.stdout.write(JSON.stringify({ status: { traffic: [{ tag: 'candidate', url: process.env.MOCK_URL }] } }));
} else process.exit(99);
`,
    { mode: 0o700 },
  );
  await writeFile(
    path.join(directory, "curl"),
    `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
if (!args.includes('--max-filesize') || !args.includes('4096') || !args.includes('=https')) process.exit(99);
fs.writeFileSync(process.env.RELEASE_DIRECTORY + '/curl-called', 'yes');
fs.writeFileSync(args[args.indexOf('--output') + 1], process.env.MOCK_BODY);
if (process.env.MOCK_CURL_FAILURE === 'true') process.exit(28);
process.stdout.write(process.env.MOCK_HTTP);
`,
    { mode: 0o700 },
  );
  const result = spawnSync(
    "bash",
    [path.join(root, "ops/google-release-driver.sh"), "authentication-smoke"],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${directory}:${process.env.PATH}`,
        RELEASE_DIRECTORY: directory,
        STATE_BUCKET: "state-test",
        RECEIPT_BUCKET: "receipts-test",
        GITHUB_SHA: commit,
        GITHUB_RUN_ID: "123",
        GITHUB_RUN_ATTEMPT: "1",
        MOCK_READY: options.ready ?? "True",
        MOCK_URL: options.url ?? "https://candidate.example.run.app",
        MOCK_LOOKUP_FAILURE: String(options.lookupFailure ?? false),
        MOCK_CURL_FAILURE: String(options.curlFailure ?? false),
        MOCK_BODY: options.body ?? JSON.stringify(healthy),
        MOCK_HTTP: options.http ?? "200",
      },
    },
  );
  const files = await readdir(directory);
  assert.ok(
    !files.some((name) => name.startsWith("health.")),
    "health response must be removed",
  );
  assert.doesNotMatch(
    result.stdout + result.stderr,
    /fixture-private-response|candidate\.example\.run\.app|workload-test/,
  );
  const operations = JSON.parse(
    await readFile(path.join(directory, "operations.json"), "utf8"),
  );
  assert.equal(
    operations.health.authentication,
    result.status === 0 ? "passed" : "not-run",
  );
  return { ...result, curlCalled: files.includes("curl-called") };
}

test("candidate smoke accepts the exact healthy contract", async (t) => {
  assert.equal((await smoke(t)).status, 0);
});

for (const dependency of Object.keys(healthy)) {
  test(`candidate smoke identifies ${dependency} without raw diagnostics`, async (t) => {
    const body = JSON.stringify({
      ...healthy,
      [dependency]: { status: "down" },
    });
    const result = await smoke(t, { body });
    assert.equal(result.status, 70);
    assert.ok(result.stderr.includes(`${dependency}=down`));
  });
}

for (const body of [
  "",
  `${JSON.stringify(healthy)}\n${JSON.stringify(healthy)}`,
  "fixture-private-response",
  "null",
  "[]",
  "{}",
  JSON.stringify({ ...healthy, detail: "fixture-private-response" }),
  JSON.stringify({
    ...healthy,
    "client:smtp": { status: "fixture-private-response" },
  }),
  JSON.stringify({
    ...healthy,
    "client:smtp": { status: "up", error: "fixture-private-response" },
  }),
]) {
  test(`candidate smoke rejects malformed response ${body.slice(0, 20)}`, async (t) => {
    const result = await smoke(t, { body });
    assert.equal(result.status, 70);
    assert.match(result.stderr, /unexpected health response schema/);
  });
}

test("candidate smoke separates transport and HTTP failures", async (t) => {
  const transport = await smoke(t, { curlFailure: true });
  assert.equal(transport.status, 70);
  assert.match(transport.stderr, /HTTPS request failed/);
  const http = await smoke(t, {
    http: "503",
    body: "fixture-private-response",
  });
  assert.equal(http.status, 70);
  assert.match(http.stderr, /did not return HTTP 200/);
});

test("candidate smoke never requests an unresolved or unready candidate", async (t) => {
  for (const options of [
    { ready: "False" },
    { lookupFailure: true },
    { url: "http://example.test" },
  ]) {
    const result = await smoke(t, options);
    assert.equal(result.status, 70);
    assert.equal(result.curlCalled, false);
  }
});

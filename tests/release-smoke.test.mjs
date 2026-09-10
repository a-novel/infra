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
const unavailable = {
  ...healthy,
  "api:jsonKeys": { status: "down" },
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
for (const [flag, value] of [['--max-filesize', '4096'], ['--max-time', '15'], ['--connect-timeout', '5'], ['--proto', '=https']]) {
  if (args[args.indexOf(flag) + 1] !== value) process.exit(99);
}
const callsFile = process.env.RELEASE_DIRECTORY + '/curl-calls';
const calls = fs.existsSync(callsFile) ? fs.readFileSync(callsFile, 'utf8').trim().split('\\n').length : 0;
fs.appendFileSync(callsFile, args.at(-1) + '\\n');
const responses = JSON.parse(process.env.MOCK_RESPONSES);
const response = responses[Math.min(calls, responses.length - 1)];
fs.writeFileSync(args[args.indexOf('--output') + 1], response.body);
if (response.curlFailure) process.exit(28);
process.stdout.write(response.http);
`,
    { mode: 0o700 },
  );
  await writeFile(
    path.join(directory, "sleep"),
    `#!${process.execPath}
require('node:fs').appendFileSync(process.env.RELEASE_DIRECTORY + '/sleep-calls', process.argv.slice(2).join(' ') + '\\n');
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
        MOCK_RESPONSES: JSON.stringify(
          (options.responses ?? [options]).map((response) => ({
            curlFailure: response.curlFailure ?? false,
            body: response.body ?? JSON.stringify(healthy),
            http: response.http ?? "200",
          })),
        ),
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
  const calls = files.includes("curl-calls")
    ? (await readFile(path.join(directory, "curl-calls"), "utf8"))
        .trim()
        .split("\n")
    : [];
  const sleeps = files.includes("sleep-calls")
    ? (await readFile(path.join(directory, "sleep-calls"), "utf8"))
        .trim()
        .split("\n")
    : [];
  assert.ok(
    calls.every(
      (url) =>
        url ===
        `${options.url ?? "https://candidate.example.run.app"}/v2/healthcheck`,
    ),
  );
  assert.ok(sleeps.every((seconds) => seconds === "5"));
  assert.equal(sleeps.length, Math.max(0, calls.length - 1));
  return { ...result, calls: calls.length };
}

test("candidate smoke accepts the exact healthy contract", async (t) => {
  const result = await smoke(t);
  assert.equal(result.status, 0);
  assert.equal(result.calls, 1);
});

for (const http of ["200", "503"]) {
  for (const dependency of Object.keys(healthy)) {
    test(`candidate smoke identifies ${dependency} on HTTP ${http} without raw diagnostics`, async (t) => {
      const body = JSON.stringify({
        ...healthy,
        [dependency]: { status: "down" },
      });
      const result = await smoke(t, { body, http });
      assert.equal(result.status, 70);
      assert.equal(result.calls, 3);
      for (const component of Object.keys(healthy)) {
        assert.ok(
          result.stderr.includes(
            `${component}=${component === dependency ? "down" : "up"}`,
          ),
        );
      }
    });
  }
}

test("candidate smoke rejects HTTP 503 even with healthy dependency statuses", async (t) => {
  const result = await smoke(t, { http: "503" });
  assert.equal(result.status, 70);
  assert.equal(result.calls, 1);
  assert.match(result.stderr, /endpoint returned HTTP 503/);
});

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
    for (const http of ["200", "503"]) {
      const result = await smoke(t, { body, http });
      assert.equal(result.status, 70);
      assert.equal(result.calls, 1);
      assert.match(result.stderr, /unexpected health response schema/);
      assert.doesNotMatch(result.stderr, /Authentication health:/);
    }
  });
}

test("candidate smoke separates transport and HTTP failures", async (t) => {
  const transport = await smoke(t, { curlFailure: true });
  assert.equal(transport.status, 70);
  assert.equal(transport.calls, 1);
  assert.match(transport.stderr, /HTTPS request failed/);
  const http = await smoke(t, {
    http: "403",
    body: "fixture-private-response",
  });
  assert.equal(http.status, 70);
  assert.equal(http.calls, 1);
  assert.match(http.stderr, /endpoint returned HTTP 403/);
  assert.doesNotMatch(http.stderr, /Authentication health:/);
});

test("candidate smoke never requests an unresolved or unready candidate", async (t) => {
  for (const options of [
    { ready: "False" },
    { lookupFailure: true },
    { url: "http://example.test" },
  ]) {
    const result = await smoke(t, options);
    assert.equal(result.status, 70);
    assert.equal(result.calls, 0);
  }
});

test("candidate smoke never prints an invalid HTTP status", async (t) => {
  const result = await smoke(t, { http: "fixture-private-response" });
  assert.equal(result.status, 70);
  assert.equal(result.calls, 1);
  assert.match(result.stderr, /unexpected HTTP status/);
});

for (const http of ["200", "503"]) {
  for (const failures of [1, 2]) {
    test(`candidate smoke recovers after ${failures} valid HTTP ${http} down responses`, async (t) => {
      const result = await smoke(t, {
        responses: [
          ...Array(failures).fill({ http, body: JSON.stringify(unavailable) }),
          {},
        ],
      });
      assert.equal(result.status, 0);
      assert.equal(result.calls, failures + 1);
    });
  }
}

test("candidate smoke stops retrying when a terminal failure follows a down response", async (t) => {
  for (const terminal of [
    { curlFailure: true },
    { http: "403" },
    { http: "503" },
    { body: "fixture-private-response" },
  ]) {
    const result = await smoke(t, {
      responses: [
        { http: "503", body: JSON.stringify(unavailable) },
        terminal,
        {},
      ],
    });
    assert.equal(result.status, 70);
    assert.equal(result.calls, 2);
  }
});

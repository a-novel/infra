import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sha = "1".repeat(40);
const head = "a".repeat(40);
const project = "recovery-project-prod";
const receipt = "101-3";
const runUrl = "https://github.com/a-novel/infra/actions/runs/202";
const response = { workflow_run_id: 202, html_url: runUrl };
const dispatches = (calls) =>
  calls.filter((call) => call[1]?.endsWith("/dispatches"));
const watchers = (calls) =>
  calls.filter((call) => call[0] === "run" && call[1] === "watch");

async function run(t, args, overrides = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "infra-dispatch-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const command of ["gh", "git"]) {
    await symlink(
      path.join(root, `tests/fixtures/fake-workflow-${command}.sh`),
      path.join(directory, command),
    );
  }
  const log = path.join(directory, "calls.jsonl");
  await writeFile(log, "");
  const result = spawnSync("bash", ["ops/run-workflow.sh", ...args], {
    cwd: root,
    encoding: "utf8",
    timeout: 10000,
    env: {
      ...process.env,
      PATH: `${directory}:${process.env.PATH}`,
      FAKE_WORKFLOW_CALLS: log,
      FAKE_WORKFLOW_SHA: sha,
      FAKE_WORKFLOW: `${args[0]}.yaml`,
      ...Object.fromEntries(
        Object.entries(overrides).map(([key, value]) => [
          key,
          typeof value === "string" ? value : JSON.stringify(value),
        ]),
      ),
    },
  });
  assert.equal(result.error, undefined);
  return {
    ...result,
    calls: (await readFile(log, "utf8"))
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse),
  };
}

const cases = [
  [["drift"], { operation: "drift" }, "202"],
  [
    ["drift", "assess-pull-request", "93"],
    {
      operation: "assess-pull-request",
      pull_request: "93",
      head_sha: head,
      base_sha: sha,
    },
    "202",
  ],
  ...["bootstrap", "foundation"].flatMap((name) => [
    [["foundation", "plan", name], { operation: "plan", root: name }, "202-3"],
    [
      ["foundation", "apply", name, receipt],
      { operation: "apply", root: name, plan_id: receipt },
      "202",
      {
        FAKE_PLAN_OVERRIDE: {
          display_title: `foundation plan ${name} by @operator`,
        },
      },
    ],
  ]),
  [["release", "deploy"], { action: "deploy" }, "202"],
  [
    ["release", "deploy", "--no-wait"],
    { action: "deploy" },
    "202",
    {
      FAKE_RUN_OVERRIDE: { status: "queued", conclusion: null },
    },
  ],
  [
    ["release", "rollback", receipt],
    { action: "rollback", target_receipt: receipt },
    "202",
  ],
  [
    ["release", "recover-first-launch", "678"],
    { action: "recover-first-launch", failed_run_id: "678" },
    "202",
  ],
  ...["drill", "restore"].map((action) => [
    [
      "release",
      `${action}-database-isolation`,
      receipt,
      `${action.toUpperCase()} authentication`,
    ],
    {
      action: `${action}-database-isolation`,
      target_receipt: receipt,
      confirm_isolation: `${action.toUpperCase()} authentication`,
    },
    "202",
  ]),
  ...["plan-workload", "apply-workload", "restore-data", "cleanup-project"].map(
    (operation) => {
      const extras = {
        "plan-workload": {},
        "apply-workload": { plan_id: receipt },
        "restore-data": {
          json_keys_attempt: "100-json-1",
          authentication_attempt: "101-authentication-1",
          lost_write_window: '@literal {value} = "no known lost writes"',
          confirm: `RESTORE ${project}`,
        },
        "cleanup-project": { confirm: `DELETE ${project}` },
      }[operation];
      return [
        ["recovery", operation, project, receipt, ...Object.values(extras)],
        {
          operation,
          replacement_project_id: project,
          target_receipt: receipt,
          ...extras,
        },
        ["plan-workload", "restore-data"].includes(operation) ? "202-3" : "202",
        {
          FAKE_PLAN_OVERRIDE: {
            display_title: `recovery plan-workload ${project} by @operator`,
          },
        },
      ];
    },
  ),
];

for (const [args, inputs, output, env] of cases) {
  test(`dispatches exact inputs: ${args.join(" ")}`, async (t) => {
    const result = await run(t, args, env);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `${output}\n`);
    assert.ok(result.stderr.includes(runUrl));
    assert.deepEqual(dispatches(result.calls), [
      [
        "api",
        `repos/a-novel/infra/actions/workflows/${args[0]}.yaml/dispatches`,
        "--method",
        "POST",
        "-H",
        "X-GitHub-Api-Version: 2026-03-10",
        "-f",
        "ref=master",
        ...Object.entries(inputs).flatMap(([key, value]) => [
          "-f",
          `inputs[${key}]=${value}`,
        ]),
      ],
    ]);
    assert.equal(
      watchers(result.calls).length,
      args.includes("--no-wait") ? 0 : 1,
    );
  });
}

for (const [name, env, code] of [
  ["wrong branch", { FAKE_GIT_BRANCH: "topic" }, 65],
  ["dirty checkout", { FAKE_GIT_DIRTY: "true" }, 65],
  ["stale master", { FAKE_REMOTE_WORKFLOW_SHA: "0".repeat(40) }, 65],
  ["active writer", { FAKE_ACTIVE_WORKFLOW: "true" }, 75],
  ["stale plan", { FAKE_PLAN_OVERRIDE: { head_sha: "0".repeat(40) } }, 65],
  [
    "wrong plan operation",
    {
      FAKE_PLAN_OVERRIDE: {
        display_title: "foundation apply foundation by @operator",
      },
    },
    65,
  ],
  ["failed plan", { FAKE_PLAN_OVERRIDE: { conclusion: "failure" } }, 65],
  ["rerun plan", { FAKE_PLAN_OVERRIDE: { run_attempt: 4 } }, 65],
]) {
  test(`refuses before dispatch: ${name}`, async (t) => {
    const result = await run(
      t,
      ["foundation", "apply", "foundation", receipt],
      env,
    );
    assert.equal(result.status, code, result.stderr);
    assert.equal(result.stdout, "");
    assert.equal(dispatches(result.calls).length, 0);
  });
}

for (const args of [
  ["foundation", "plan"],
  ["release", "recover-first-launch", "invalid"],
  ["release", "drill-database-isolation", receipt, "DRILL json-keys"],
  [
    "recovery",
    "restore-data",
    project,
    receipt,
    "100-json-1",
    "101-authentication-1",
    "no lost writes",
    "RESTORE wrong-project",
  ],
]) {
  test(`invalid intent never calls GitHub: ${args.join(" ")}`, async (t) => {
    const result = await run(t, args);
    assert.equal(result.status, 64);
    assert.deepEqual(result.calls, []);
  });
}

for (const [name, env] of [
  ["lost response", { FAKE_DISPATCH_FAILURE: "true" }],
  ...[
    "",
    "private-invalid-json",
    "{}",
    "null",
    "[]",
    JSON.stringify(response) + JSON.stringify(response),
    ...[0, -1, 1.5, "202", 9007199254740992].map((id) =>
      JSON.stringify({ ...response, workflow_run_id: id }),
    ),
    JSON.stringify({
      ...response,
      html_url: "https://example.invalid/private-url",
    }),
  ].map((body, index) => [
    `invalid response ${index}`,
    { FAKE_DISPATCH_RESPONSE: body },
  ]),
  ["unavailable run metadata", { FAKE_RUN_READ_FAILURE: "true" }],
  ...[
    { id: 999 },
    { head_sha: "0".repeat(40) },
    { path: ".github/workflows/foundation.yaml" },
    { event: "push" },
    { head_branch: "topic" },
  ].map((value) => [
    `wrong identity ${Object.keys(value)[0]}`,
    { FAKE_RUN_OVERRIDE: value },
  ]),
]) {
  test(`stops without guessing or redispatching: ${name}`, async (t) => {
    const result = await run(t, ["release", "deploy", "--no-wait"], env);
    assert.equal(result.status, 70, result.stderr);
    assert.equal(result.stdout, "");
    assert.equal(dispatches(result.calls).length, 1);
    assert.equal(watchers(result.calls).length, 0);
    assert.match(result.stderr, /Inspect .* before retrying/);
    assert.doesNotMatch(result.stderr, /private-invalid-json|private-url/);
  });
}

for (const env of [
  { FAKE_WORKFLOW_WATCH_FAILURE: "true" },
  ...[
    { status: "in_progress" },
    { conclusion: "failure" },
    { conclusion: "skipped" },
    { run_attempt: 0 },
    { run_attempt: 1.5 },
  ].map((value) => ({ FAKE_RUN_OVERRIDE: value })),
]) {
  test(`failed completion cannot return a plan ID: ${JSON.stringify(env)}`, async (t) => {
    const result = await run(t, ["foundation", "plan", "foundation"], env);
    assert.notEqual(result.status, 0);
    assert.equal(result.stdout, "");
    assert.equal(dispatches(result.calls).length, 1);
    assert.equal(watchers(result.calls).length, 1);
  });
}

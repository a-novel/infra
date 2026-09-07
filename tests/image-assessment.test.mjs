import {
  dispatchImageAssessments,
  imageValuesOnly,
  verifyImageAssessment,
} from "../ops/assess-image-updates.mjs";

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

const repository = "a-novel/infra";
const prefix = `repos/${repository}`;
const head = "a".repeat(40);
const base = "b".repeat(40);
const manifestPath = "deploy/production/images.yaml";
const mainPath = ".github/workflows/main.yaml";
const previous = `components:\n  example:\n    enabled: true\n    images:\n      rest:\n        repository: ghcr.io/a-novel/example/rest\n        tag: v1.0.0\n        digest: sha256:${"1".repeat(64)}\n`;
const next = previous
  .replace("v1.0.0", "v1.0.1")
  .replace("1".repeat(64), "2".repeat(64));

function fixture() {
  const pull = {
    number: 42,
    state: "open",
    draft: false,
    changed_files: 1,
    user: { login: "anovelbot-dependencies[bot]", type: "Bot" },
    base: { ref: "master", sha: base, repo: { full_name: repository } },
    head: {
      ref: "renovate/authentication",
      sha: head,
      repo: { full_name: repository },
    },
  };
  const run = {
    id: 100,
    workflow_id: 50,
    path: mainPath,
    event: "pull_request",
    repository: { full_name: repository },
    head_repository: { full_name: repository },
    head_branch: pull.head.ref,
    head_sha: head,
    status: "completed",
    conclusion: "failure",
    run_attempt: 1,
  };
  const state = {
    pull,
    run,
    jobs: [
      "validate-opentofu",
      "scan-infrastructure",
      "lint-repository",
      "resource-deletion-gate",
    ].map((name) => ({
      name,
      run_id: 100,
      run_attempt: 1,
      status: "completed",
      conclusion: name === "resource-deletion-gate" ? "failure" : "success",
    })),
    files: [{ filename: manifestPath, status: "modified" }],
    workflow: { id: 50, path: mainPath },
    runs: [run],
    assessments: [],
    master: base,
    posts: [],
    calls: [],
    blobs: new Map(),
    trees: new Map(),
    target: { repository, number: 42, head, base },
    options: {
      repository,
      base,
      event: {
        action: "completed",
        repository: { full_name: repository },
        workflow_run: { id: 100 },
      },
    },
  };
  state.setBlob = (commit, path, value) => {
    const bytes = Buffer.from(value);
    const hash = createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex");
    state.blobs.set(hash, {
      sha: hash,
      encoding: "base64",
      size: bytes.length,
      content: bytes.toString("base64"),
    });
    const tree = state.trees.get(commit) ?? { truncated: false, tree: [] };
    tree.tree = tree.tree.filter((entry) => entry.path !== path);
    tree.tree.push({
      path,
      mode: "100644",
      type: "blob",
      sha: hash,
      size: bytes.length,
    });
    state.trees.set(commit, tree);
  };
  state.setBlob(base, manifestPath, previous);
  state.setBlob(head, manifestPath, next);
  for (const commit of [head, base])
    state.setBlob(commit, mainPath, "trusted workflow");
  state.api = async (path, { method = "GET", body, paginate = false } = {}) => {
    state.calls.push(path);
    await state.before?.(path, method);
    if (method === "POST") {
      assert.equal(path, `${prefix}/actions/workflows/drift.yaml/dispatches`);
      state.posts.push(body);
      return null;
    }
    let value;
    if (path === `${prefix}/pulls/42`) value = state.pull;
    else if (path.includes("/files?")) value = [[], state.files];
    else if (path.includes("/git/trees/"))
      value = state.trees.get(path.split("/").at(-1).split("?")[0]);
    else if (path.includes("/git/blobs/"))
      value = state.blobs.get(path.split("/").at(-1));
    else if (path === `${prefix}/actions/workflows/main.yaml`)
      value = state.workflow;
    else if (path.includes("/main.yaml/runs?"))
      value = [{ workflow_runs: [] }, { workflow_runs: state.runs }];
    else if (path === `${prefix}/actions/runs/100`) value = state.run;
    else if (path.includes("/jobs?filter=latest&per_page=100"))
      value = [{ jobs: [] }, { jobs: state.jobs }];
    else if (path === `${prefix}/git/ref/heads/master`)
      value = { object: { sha: state.master } };
    else if (path.includes("/commits/") || path.includes("/pulls?"))
      value = [state.pulls ?? [state.pull]];
    else if (path.includes("/drift.yaml/runs?"))
      value = [{ workflow_runs: state.assessments }];
    else assert.fail(`Unexpected endpoint: ${path}`);
    assert.notEqual(value, undefined, path);
    assert.equal(Array.isArray(value), paginate, path);
    return structuredClone(value);
  };
  state.verify = () => verifyImageAssessment(state.target, state.api);
  state.dispatch = () => dispatchImageAssessments(state.options, state.api);
  return state;
}

test("valid image update passes even when the deletion gate is red", async () => {
  const state = fixture();
  assert.equal(await state.verify(), true);
  assert.deepEqual(await state.dispatch(), [42]);
  assert.deepEqual(state.posts, [
    {
      ref: "master",
      inputs: {
        operation: "assess-image-update",
        pull_request: "42",
        head_sha: head,
        base_sha: base,
      },
    },
  ]);
  assert.ok(state.calls.every((path) => !/artifacts|logs|secrets/.test(path)));
});

for (const [name, value] of Object.entries({
  identical: previous,
  repository: next.replace(
    "ghcr.io/a-novel/example/rest",
    "attacker.invalid/image",
  ),
  enabled: next.replace("enabled: true", "enabled: false"),
  structure: next.replace("example:", "another:"),
  comment: `${next}# extra\n`,
  anchor: next.replace("v1.0.1", "&tag v1.0.1"),
  command: next.replace("v1.0.1", "$(id)"),
  prerelease: next.replace("v1.0.1", "v1.0.1-rc.1"),
  digest: next.replace("sha256:", "sha512:"),
  oversized: "x".repeat(65537),
}))
  test(`manifest rejects ${name}`, () =>
    assert.equal(imageValuesOnly(previous, value), false));

for (const [name, mutate] of Object.entries({
  human: (s) => {
    s.pull.user.type = "User";
  },
  otherBot: (s) => {
    s.pull.user.login = "other[bot]";
  },
  fork: (s) => {
    s.pull.head.repo.full_name = "other/infra";
  },
  closed: (s) => {
    s.pull.state = "closed";
  },
  draft: (s) => {
    s.pull.draft = true;
  },
  baseBranch: (s) => {
    s.pull.base.ref = "develop";
  },
  staleHead: (s) => {
    s.pull.head.sha = "c".repeat(40);
  },
  staleBase: (s) => {
    s.pull.base.sha = "c".repeat(40);
  },
  staleMaster: (s) => {
    s.master = "c".repeat(40);
  },
  extraFile: (s) => {
    s.files.push({ filename: "bootstrap/main.tf", status: "modified" });
  },
  incompleteInventory: (s) => {
    s.pull.changed_files = 2;
  },
  rename: (s) => {
    s.files[0].previous_filename = "other.yaml";
  },
  removed: (s) => {
    s.files[0].status = "removed";
  },
  symlink: (s) => {
    s.trees.get(head).tree[0].mode = "120000";
  },
  executable: (s) => {
    s.trees.get(head).tree[0].mode = "100755";
  },
  submodule: (s) => {
    s.trees.get(head).tree[0].type = "commit";
  },
  workflowChanged: (s) => {
    s.setBlob(head, mainPath, "untrusted workflow");
  },
  missingCI: (s) => {
    s.runs = [];
  },
  pushOnly: (s) => {
    s.run.event = "push";
  },
  untrustedWorkflow: (s) => {
    s.run.workflow_id = 51;
  },
  wrongRunPath: (s) => {
    s.run.path = ".github/workflows/other.yaml";
  },
  runningCI: (s) => {
    s.run.status = "in_progress";
  },
  failedLint: (s) => {
    s.jobs[2].conclusion = "failure";
  },
  skippedScan: (s) => {
    s.jobs[1].conclusion = "skipped";
  },
  missingJob: (s) => {
    s.jobs.shift();
  },
  duplicateJob: (s) => {
    s.jobs.push(s.jobs[0]);
  },
  wrongAttempt: (s) => {
    s.jobs[0].run_attempt = 2;
  },
  wrongJobRun: (s) => {
    s.jobs[0].run_id = 101;
  },
}))
  test(`authorization rejects ${name}`, async () => {
    const state = fixture();
    mutate(state);
    assert.equal(await state.verify(), false);
    assert.deepEqual(state.posts, []);
  });

test("gate-only reruns preserve successful validation from earlier attempts", async () => {
  const state = fixture();
  state.run.run_attempt = 2;
  state.jobs[3].run_attempt = 2;
  assert.equal(await state.verify(), true);
});

test("incomplete trees and corrupt blobs fail closed", async () => {
  const state = fixture();
  state.trees.get(head).truncated = true;
  await assert.rejects(state.verify(), /inventoried/);
  state.trees.get(head).truncated = false;
  const blob = state.blobs.get(state.trees.get(head).tree[0].sha);
  blob.content = Buffer.from("corrupted").toString("base64");
  await assert.rejects(state.verify(), /verified/);
});

test("a new head appearing after validation is not dispatched", async () => {
  const state = fixture();
  let reads = 0;
  state.before = (path) => {
    if (path === `${prefix}/pulls/42` && ++reads === 2)
      state.pull.head.sha = "c".repeat(40);
  };
  assert.deepEqual(await state.dispatch(), []);
});

for (const status of ["queued", "in_progress", "completed"])
  test(`existing ${status} verdict request is not duplicated`, async () => {
    const state = fixture();
    state.assessments = [
      {
        path: ".github/workflows/drift.yaml",
        event: "workflow_dispatch",
        head_branch: "master",
        head_sha: base,
        status,
        conclusion: "failure",
        display_title: `resource-deletion assessment PR #42 ${head} onto ${base}`,
      },
    ];
    assert.deepEqual(await state.dispatch(), []);
  });

test("old tuple verdict does not suppress a fresh assessment", async () => {
  const state = fixture();
  state.assessments = [
    {
      display_title: `resource-deletion assessment PR #42 ${"c".repeat(40)} onto ${base}`,
    },
  ];
  assert.deepEqual(await state.dispatch(), [42]);
});

test("master CI completion reassesses eligible open PRs", async () => {
  const state = fixture();
  const prRun = structuredClone(state.run);
  const api = state.api;
  state.run = {
    ...prRun,
    id: 200,
    event: "push",
    head_branch: "master",
    head_sha: base,
    conclusion: "success",
  };
  state.options.event.workflow_run.id = 200;
  state.api = async (path, options) => {
    if (path === `${prefix}/actions/runs/200`) return state.run;
    if (path === `${prefix}/actions/runs/100`) return prRun;
    return api(path, options);
  };
  assert.deepEqual(await state.dispatch(), [42]);
  assert.ok(
    state.calls.includes(`${prefix}/pulls?state=open&base=master&per_page=100`),
  );
});

test("untrusted completion metadata cannot trigger dispatch", async () => {
  const state = fixture();
  state.options.event.repository.full_name = "other/infra";
  assert.deepEqual(await state.dispatch(), []);
  assert.deepEqual(state.calls, []);
});

test("GitHub read failure propagates without dispatch", async () => {
  const state = fixture();
  state.before = () => {
    throw new Error("unavailable");
  };
  await assert.rejects(state.dispatch(), /unavailable/);
  assert.deepEqual(state.posts, []);
});

test("an existing production assessment keeps the next request out of GitHub's pending slot", async () => {
  const state = fixture();
  state.assessments = [{ status: "queued" }];
  assert.deepEqual(await state.dispatch(), []);
});

test("a completed drift assessment picks one eligible open PR at a time", async () => {
  const state = fixture();
  const prRun = structuredClone(state.run);
  const api = state.api;
  state.run = {
    ...prRun,
    id: 200,
    workflow_id: 60,
    path: ".github/workflows/drift.yaml",
    event: "workflow_dispatch",
    head_branch: "master",
    head_sha: base,
    conclusion: "success",
  };
  state.options.event.workflow_run.id = 200;
  state.pulls = [state.pull, state.pull];
  state.api = async (path, options) => {
    if (path === `${prefix}/actions/runs/200`) return state.run;
    if (path === `${prefix}/actions/runs/100`) return prRun;
    if (path === `${prefix}/actions/workflows/drift.yaml`)
      return { id: 60, path: ".github/workflows/drift.yaml" };
    return api(path, options);
  };
  assert.deepEqual(await state.dispatch(), [42]);
  assert.equal(state.posts.length, 1);
});

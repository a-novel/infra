import assert from "node:assert/strict";
import test from "node:test";

import { refreshDeletionGates } from "../ops/refresh-deletion-gates.mjs";

const repository = "a-novel/infra";
const head = "a".repeat(40);
const base = "b".repeat(40);
const trustedMainSha = "c".repeat(40);
const before = "2026-09-07T01:00:00Z";
const changed = "2026-09-07T01:01:00Z";
const after = "2026-09-07T01:02:00Z";
const prefix = `repos/${repository}`;

function fixture() {
  const pull = {
    number: 42,
    state: "open",
    base: { ref: "master", sha: base, repo: { full_name: repository } },
    head: { ref: "fix/ci/example", sha: head, repo: { full_name: repository } },
  };
  const assessment = {
    id: 300,
    path: ".github/workflows/drift.yaml",
    repository: { full_name: repository },
    event: "workflow_dispatch",
    head_branch: "master",
    head_sha: base,
    status: "completed",
    conclusion: "success",
    updated_at: changed,
    display_title: `resource-deletion assessment PR #42 ${head} onto ${base}`,
  };
  const runs = ["push", "pull_request"].map((event, index) => ({
    id: 100 + index,
    workflow_id: 50,
    path: ".github/workflows/main.yaml",
    event,
    repository: { full_name: repository },
    head_repository: { full_name: repository },
    head_branch: pull.head.ref,
    head_sha: head,
    status: "completed",
    conclusion: "failure",
    run_attempt: 1,
  }));
  const jobs = new Map(
    runs.map((run) => [
      run.id,
      [
        {
          id: run.id * 10,
          run_id: run.id,
          run_attempt: run.run_attempt,
          name: "resource-deletion-gate",
          status: "completed",
          conclusion: "failure",
          started_at: before,
        },
      ],
    ]),
  );
  const state = {
    pull,
    assessment,
    runs,
    jobs,
    labels: [],
    assessments: [assessment],
    candidateSha: trustedMainSha,
    posts: [],
    calls: [],
  };
  state.options = {
    repository,
    trustedMainSha,
    eventName: "workflow_run",
    event: {
      action: "completed",
      repository: { full_name: repository },
      workflow_run: { id: assessment.id },
    },
  };
  state.api = async (path, { method = "GET", paginate = false } = {}) => {
    state.calls.push({ path, method });
    await state.beforeRequest?.(path, method);
    if (method === "POST") {
      assert.match(
        path,
        /^repos\/a-novel\/infra\/actions\/jobs\/10[01]0\/rerun$/,
      );
      state.posts.push(path);
      const id = Number(path.split("/").at(-2));
      state.runs.find((run) => run.id === id / 10).status = "queued";
      return null;
    }
    assert.equal(method, "GET");
    let result;
    if (path === `${prefix}/pulls/42`) result = state.pull;
    else if (path === `${prefix}/actions/runs/300`) result = state.assessment;
    else if (path === `${prefix}/commits/${head}/pulls?per_page=100`)
      result = [state.associatedPulls ?? [state.pull]];
    else if (path === `${prefix}/issues/42/events?per_page=100`)
      result = [[], state.labels];
    else if (path.startsWith(`${prefix}/actions/workflows/drift.yaml/runs?`))
      result = [{ workflow_runs: [] }, { workflow_runs: state.assessments }];
    else if (path === `${prefix}/actions/workflows/main.yaml`)
      result = { id: 50, path: ".github/workflows/main.yaml" };
    else if (
      path === `${prefix}/contents/.github/workflows/main.yaml?ref=${head}`
    )
      result = { sha: state.candidateSha };
    else if (
      path ===
      `${prefix}/actions/workflows/main.yaml/runs?head_sha=${head}&per_page=100`
    )
      result = [{ workflow_runs: state.runs }];
    else {
      const runPath = /^repos\/a-novel\/infra\/actions\/runs\/(\d+)$/.exec(
        path,
      );
      const jobPath =
        /^repos\/a-novel\/infra\/actions\/runs\/(\d+)\/attempts\/(\d+)\/jobs\?per_page=100$/.exec(
          path,
        );
      if (runPath)
        result = state.runs.find((run) => run.id === Number(runPath[1]));
      else if (jobPath) {
        assert.equal(
          Number(jobPath[2]),
          state.runs.find((run) => run.id === Number(jobPath[1])).run_attempt,
        );
        result = [{ jobs: [] }, { jobs: state.jobs.get(Number(jobPath[1])) }];
      } else assert.fail(`Unexpected endpoint: ${path}`);
    }
    assert.equal(Array.isArray(result), paginate, path);
    return structuredClone(result);
  };
  state.refresh = () => refreshDeletionGates(state.options, state.api);
  state.useLabel = (action = "labeled") => {
    state.options.eventName = "pull_request_target";
    state.options.event = {
      action,
      repository: { full_name: repository },
      pull_request: structuredClone(state.pull),
      label: { name: "allow-resource-deletion" },
    };
    state.labels = [
      {
        event: action,
        label: { name: "allow-resource-deletion" },
        created_at: changed,
      },
    ];
  };
  return state;
}

test("assessment completion refreshes only both current deletion jobs", async () => {
  const state = fixture();
  state.jobs.get(100).push({
    id: 999,
    name: "lint-repository",
    status: "completed",
    started_at: before,
  });
  assert.deepEqual(await state.refresh(), [
    { runId: 101, jobId: 1010 },
    { runId: 100, jobId: 1000 },
  ]);
  assert.equal(state.posts.length, 2);
  assert.ok(
    state.calls.every(
      ({ path }) => !/artifacts|dispatches|check-runs|logs/.test(path),
    ),
  );
});

for (const action of ["labeled", "unlabeled"]) {
  test(`${action} refreshes both gates, including previously green ones`, async () => {
    const state = fixture();
    state.useLabel(action);
    state.assessments = [];
    for (const gates of state.jobs.values()) gates[0].conclusion = "success";
    assert.equal((await state.refresh()).length, 2);
  });
}

test("a failed latest assessment refreshes prior green gates", async () => {
  const state = fixture();
  state.assessment.conclusion = "failure";
  for (const gates of state.jobs.values()) gates[0].conclusion = "success";
  assert.equal((await state.refresh()).length, 2);
});

test("CI completion catches a label change that arrived during the run", async () => {
  const state = fixture();
  state.useLabel("unlabeled");
  state.assessments = [];
  state.runs.forEach((run) => {
    run.status = "in_progress";
  });
  assert.deepEqual(await state.refresh(), []);
  state.runs.forEach((run) => {
    run.status = "completed";
  });
  state.options.eventName = "workflow_run";
  state.options.event = {
    action: "completed",
    repository: { full_name: repository },
    workflow_run: { id: 100 },
  };
  assert.equal((await state.refresh()).length, 2);
});

test("duplicate events and rerun completion cannot cause a retry loop", async () => {
  const state = fixture();
  assert.equal((await state.refresh()).length, 2);
  assert.deepEqual(await state.refresh(), []);
  for (const run of state.runs) {
    run.status = "completed";
    run.run_attempt = 2;
    Object.assign(state.jobs.get(run.id)[0], {
      started_at: after,
      run_attempt: 2,
    });
  }
  state.options.event.workflow_run.id = 100;
  assert.deepEqual(await state.refresh(), []);
  assert.equal(state.posts.length, 2);
});

test("only the newest run of each event is selected, including active runs", async () => {
  const state = fixture();
  state.runs.push({ ...state.runs[0], id: 200, status: "in_progress" });
  assert.deepEqual(await state.refresh(), [{ runId: 101, jobId: 1010 }]);
});

test("gate started after evidence remains unchanged even when unrelated CI failed", async () => {
  const state = fixture();
  for (const gates of state.jobs.values()) gates[0].started_at = after;
  assert.deepEqual(await state.refresh(), []);
});

test("same-second events conservatively refresh once", async () => {
  const state = fixture();
  for (const gates of state.jobs.values()) gates[0].started_at = changed;
  assert.equal((await state.refresh()).length, 2);
});

for (const [name, mutate] of Object.entries({
  "closed PR": (s) => {
    s.pull.state = "closed";
  },
  "moved head": (s) => {
    s.pull.head.sha = "d".repeat(40);
  },
  "moved base": (s) => {
    s.pull.base.sha = "d".repeat(40);
  },
  "different base branch": (s) => {
    s.pull.base.ref = "other";
  },
  "different target repository": (s) => {
    s.pull.base.repo.full_name = "other/repo";
  },
  "unrelated workflow": (s) => {
    s.assessment.path = ".github/workflows/release.yaml";
  },
  "scheduled drift": (s) => {
    s.assessment.event = "schedule";
  },
  "assessment off master": (s) => {
    s.assessment.head_branch = "untrusted";
  },
  "assessment from another repo": (s) => {
    s.assessment.repository.full_name = "other/repo";
  },
  "malformed assessment title": (s) => {
    s.assessment.display_title += "\nfalse";
  },
  "wrong assessment base": (s) => {
    s.assessment.head_sha = head;
  },
  "unrelated label": (s) => {
    s.useLabel();
    s.options.event.label.name = "documentation";
  },
  "unrelated PR event": (s) => {
    s.useLabel();
    s.options.event.action = "opened";
  },
  "unrelated trigger": (s) => {
    s.options.eventName = "push";
  },
  "stale completion notification": (s) => {
    s.assessment.status = "in_progress";
  },
})) {
  test(`${name} performs no writes`, async () => {
    const state = fixture();
    mutate(state);
    assert.deepEqual(await state.refresh(), []);
    assert.deepEqual(state.posts, []);
  });
}

test("ordinary CI completion without assessment or label history does nothing", async () => {
  const state = fixture();
  state.options.event.workflow_run.id = 100;
  state.assessments = [];
  assert.deepEqual(await state.refresh(), []);
});

test("ambiguous PR association is not guessed", async () => {
  const state = fixture();
  state.options.event.workflow_run.id = 100;
  state.associatedPulls = [state.pull, { ...state.pull, number: 43 }];
  assert.deepEqual(await state.refresh(), []);
});

test("a run for another branch at the same SHA is ignored", async () => {
  const state = fixture();
  state.runs[0].head_branch = "other";
  assert.deepEqual(await state.refresh(), [{ runId: 101, jobId: 1010 }]);
});

test("a forged workflow ID or path is not eligible", async () => {
  const state = fixture();
  state.runs[0].workflow_id = 99;
  state.runs[1].path = ".github/workflows/release.yaml";
  assert.deepEqual(await state.refresh(), []);
});

test("candidate workflow changes require a manual review instead of an automatic rerun", async () => {
  const state = fixture();
  state.candidateSha = "d".repeat(40);
  await assert.rejects(state.refresh, /differs from trusted master/);
  assert.deepEqual(state.posts, []);
});

test("API failure before selection cannot write a passing verdict", async () => {
  const state = fixture();
  state.beforeRequest = () => {
    throw new Error("unavailable");
  };
  await assert.rejects(state.refresh, /unavailable/);
  assert.deepEqual(state.posts, []);
});

test("rerun API permission failures are surfaced", async () => {
  const state = fixture();
  state.beforeRequest = (path, method) => {
    if (method === "POST") throw new Error("forbidden");
  };
  await assert.rejects(state.refresh, /forbidden/);
  assert.deepEqual(state.posts, []);
});

test("a concurrent accepted rerun is a harmless no-op", async () => {
  const state = fixture();
  state.beforeRequest = (path, method) => {
    if (method === "POST") {
      const runId = Number(path.split("/").at(-2)) / 10;
      state.runs.find((run) => run.id === runId).status = "queued";
      throw new Error("already queued");
    }
  };
  assert.deepEqual(await state.refresh(), []);
});

test("head movement immediately before mutation prevents reruns", async () => {
  const state = fixture();
  let reads = 0;
  state.beforeRequest = (path) => {
    if (path === `${prefix}/pulls/42` && ++reads > 1)
      state.pull.head.sha = "d".repeat(40);
  };
  assert.deepEqual(await state.refresh(), []);
  assert.deepEqual(state.posts, []);
});

test("invalid event timestamps are rejected", async () => {
  const state = fixture();
  state.assessment.updated_at = "yesterday";
  await assert.rejects(state.refresh, /timestamp/);
  assert.deepEqual(state.posts, []);
});

test("only the latest assessment for the exact tuple contributes evidence", async () => {
  const state = fixture();
  state.assessments = [
    { ...state.assessment, updated_at: after },
    { ...state.assessment, id: 301, updated_at: before },
  ];
  for (const gates of state.jobs.values()) gates[0].started_at = changed;
  assert.deepEqual(await state.refresh(), []);
});

test("jobs must belong to the selected run attempt", async () => {
  const state = fixture();
  state.jobs.get(101)[0].run_attempt = 2;
  await assert.rejects(state.refresh, /selected run attempt/);
  assert.deepEqual(state.posts, []);
});

#!/usr/bin/env node

/**
 * Refresh existing deletion checks when their assessment or approval changes.
 * The gate owns the verdict; this cloud-blind workflow only requests job reruns.
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, appendFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const mainPath = ".github/workflows/main.yaml";
const driftPath = ".github/workflows/drift.yaml";
const label = "allow-resource-deletion";
const sha = /^[a-f0-9]{40}$/;
const positiveId = (value) => Number.isSafeInteger(value) && value > 0;

function timestamp(value) {
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/.test(value ?? "")) {
    throw new Error("GitHub returned an invalid event timestamp.");
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) throw new Error("Invalid event timestamp.");
  return parsed;
}

function assessmentTarget(run) {
  if (
    run.path !== driftPath ||
    run.event !== "workflow_dispatch" ||
    run.head_branch !== "master" ||
    run.status !== "completed"
  )
    return null;
  const match =
    /^resource-deletion assessment PR #([1-9][0-9]*) ([a-f0-9]{40}) onto ([a-f0-9]{40})$/.exec(
      run.display_title ?? "",
    );
  if (!match || run.head_sha !== match[3] || !positiveId(Number(match[1])))
    return null;
  return { number: Number(match[1]), head: match[2], base: match[3] };
}

/**
 * refreshDeletionGates requests only stale gate jobs for an open, current PR.
 * api supplies GitHub JSON responses; trustedMainSha identifies the reviewed workflow blob.
 */
export async function refreshDeletionGates(
  { repository, eventName, event, trustedMainSha },
  api,
) {
  if (
    !/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(
      repository ?? "",
    ) ||
    event.repository?.full_name !== repository ||
    !sha.test(trustedMainSha)
  ) {
    throw new Error("Invalid refresh repository or trusted workflow.");
  }
  const prefix = `repos/${repository}`;
  const pages = async (path, key) =>
    (await api(path, { paginate: true })).flatMap((page) =>
      key ? page[key] : page,
    );
  let target;
  if (eventName === "pull_request_target") {
    if (
      !["labeled", "unlabeled"].includes(event.action) ||
      event.label?.name !== label
    )
      return [];
    const pr = event.pull_request;
    target = { number: pr?.number, head: pr?.head?.sha, base: pr?.base?.sha };
  } else if (eventName === "workflow_run") {
    if (event.action !== "completed" || !positiveId(event.workflow_run?.id))
      return [];
    const run = await api(`${prefix}/actions/runs/${event.workflow_run.id}`);
    if (run.repository?.full_name !== repository || run.status !== "completed")
      return [];
    target = assessmentTarget(run);
    if (!target) {
      if (
        run.path !== mainPath ||
        !["push", "pull_request"].includes(run.event) ||
        run.head_branch === "master" ||
        !sha.test(run.head_sha)
      )
        return [];
      const pulls = (
        await pages(`${prefix}/commits/${run.head_sha}/pulls?per_page=100`)
      ).filter(
        (pr) =>
          pr.state === "open" &&
          pr.base?.ref === "master" &&
          pr.base.repo.full_name === repository &&
          pr.head?.sha === run.head_sha,
      );
      if (pulls.length !== 1) return [];
      target = {
        number: pulls[0].number,
        head: run.head_sha,
        base: pulls[0].base.sha,
      };
    }
  } else return [];

  if (
    !positiveId(target.number) ||
    !sha.test(target.head) ||
    !sha.test(target.base)
  )
    return [];
  const current = (pr) =>
    pr.state === "open" &&
    pr.number === target.number &&
    pr.base?.ref === "master" &&
    pr.base.repo?.full_name === repository &&
    pr.base.sha === target.base &&
    pr.head?.sha === target.head;
  const pull = await api(`${prefix}/pulls/${target.number}`);
  if (
    !current(pull) ||
    typeof pull.head.ref !== "string" ||
    !pull.head.repo?.full_name
  )
    return [];

  const events = await pages(
    `${prefix}/issues/${target.number}/events?per_page=100`,
  );
  const labels = events.filter(
    (entry) =>
      ["labeled", "unlabeled"].includes(entry.event) &&
      entry.label?.name === label,
  );
  let changedAt = Math.max(
    0,
    ...labels.map((entry) => timestamp(entry.created_at)),
  );
  const assessments = await pages(
    `${prefix}/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&head_sha=${target.base}&per_page=100`,
    "workflow_runs",
  );
  const latest = assessments
    .filter(
      (run) =>
        run.display_title ===
        `resource-deletion assessment PR #${target.number} ${target.head} onto ${target.base}`,
    )
    .sort((a, b) => b.id - a.id)[0];
  if (latest && assessmentTarget(latest))
    changedAt = Math.max(changedAt, timestamp(latest.updated_at));
  if (!changedAt) return [];

  // A rerun also executes dependent jobs. Only the reviewed main workflow is eligible.
  const workflow = await api(`${prefix}/actions/workflows/main.yaml`);
  const candidate = await api(
    `${prefix}/contents/${mainPath}?ref=${target.head}`,
  );
  if (
    workflow.path !== mainPath ||
    !positiveId(workflow.id) ||
    candidate.sha !== trustedMainSha
  ) {
    throw new Error(
      "The candidate CI workflow differs from trusted master; review and refresh it manually.",
    );
  }
  const runs = await pages(
    `${prefix}/actions/workflows/main.yaml/runs?head_sha=${target.head}&per_page=100`,
    "workflow_runs",
  );
  const selected = new Map();
  for (const run of runs.sort((a, b) => b.id - a.id)) {
    if (
      run.path === mainPath &&
      run.workflow_id === workflow.id &&
      run.repository?.full_name === repository &&
      run.head_sha === target.head &&
      run.head_branch === pull.head.ref &&
      run.head_repository?.full_name === pull.head.repo.full_name &&
      ["push", "pull_request"].includes(run.event) &&
      run.head_branch !== "master" &&
      !selected.has(run.event)
    )
      selected.set(run.event, run);
  }

  const refreshed = [];
  for (const selectedRun of selected.values()) {
    if (!positiveId(selectedRun.id)) throw new Error("Invalid CI run ID.");
    const run = await api(`${prefix}/actions/runs/${selectedRun.id}`);
    if (
      run.status !== "completed" ||
      run.head_sha !== target.head ||
      run.workflow_id !== workflow.id ||
      run.path !== mainPath ||
      !positiveId(run.run_attempt)
    )
      continue;
    const jobs = await pages(
      `${prefix}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`,
      "jobs",
    );
    const gates = jobs.filter((job) => job.name === "resource-deletion-gate");
    if (gates.length !== 1) continue;
    const gate = gates[0];
    if (
      gate.status !== "completed" ||
      !gate.started_at ||
      timestamp(gate.started_at) > changedAt
    )
      continue;
    if (
      !positiveId(gate.id) ||
      gate.run_id !== run.id ||
      gate.run_attempt !== run.run_attempt
    ) {
      throw new Error(
        "The gate job does not belong to the selected run attempt.",
      );
    }
    if (!current(await api(`${prefix}/pulls/${target.number}`)))
      return refreshed;
    // Simultaneous notifications can race; GitHub accepts only one pending rerun.
    try {
      await api(`${prefix}/actions/jobs/${gate.id}/rerun`, { method: "POST" });
    } catch (error) {
      const live = await api(`${prefix}/actions/runs/${run.id}`);
      if (live.status === "completed" && live.run_attempt === run.run_attempt)
        throw error;
      continue;
    }
    refreshed.push({ runId: run.id, jobId: gate.id });
  }
  return refreshed;
}

function github(path, { paginate = false, method = "GET" } = {}) {
  const args = ["api", path, "--method", method];
  if (paginate) args.push("--paginate", "--slurp");
  try {
    const output = execFileSync("gh", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
    return output.trim() ? JSON.parse(output) : null;
  } catch {
    throw new Error(`GitHub ${method} request failed; no verdict was changed.`);
  }
}

async function main() {
  const workflow = readFileSync(new URL(`../${mainPath}`, import.meta.url));
  const trustedMainSha = createHash("sha1")
    .update(`blob ${workflow.length}\0`)
    .update(workflow)
    .digest("hex");
  const refreshed = await refreshDeletionGates(
    {
      repository: process.env.GITHUB_REPOSITORY,
      eventName: process.env.GITHUB_EVENT_NAME,
      event: JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")),
      trustedMainSha,
    },
    github,
  );
  const summary = refreshed.length
    ? refreshed
        .map(
          ({ runId, jobId }) =>
            `Requested deletion-gate refresh: run ${runId}, job ${jobId}.`,
        )
        .join("\n")
    : "No stale completed deletion gates need refreshing.";
  console.log(summary);
  if (process.env.GITHUB_STEP_SUMMARY)
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    console.error(`::error::${error.message}`);
    process.exitCode = 1;
  });
}

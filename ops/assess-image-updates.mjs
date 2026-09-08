#!/usr/bin/env node

/** Authorizes metadata-only assessments for validated Renovate image updates. */
import { github } from "./refresh-deletion-gates.mjs";

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const manifestPath = "deploy/production/images.yaml";
const mainPath = ".github/workflows/main.yaml";
const driftPath = ".github/workflows/drift.yaml";
const sha = /^[a-f0-9]{40}$/;
const requiredJobs = [
  "validate-opentofu",
  "scan-infrastructure",
  "lint-repository",
];
const positiveId = (value) => Number.isSafeInteger(value) && value > 0;
const pages = (result, key) =>
  result.flatMap((page) => (key ? page[key] : page));

/** Allows only canonical tag/digest value edits; every other byte stays trusted. */
export function imageValuesOnly(previous, next) {
  if (previous === next || Buffer.byteLength(next) > 65536) return false;
  const before = previous.split("\n");
  const after = next.split("\n");
  const tag =
    /^        tag: v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
  const digest = /^        digest: sha256:[a-f0-9]{64}$/;
  return (
    before.length === after.length &&
    before.every(
      (line, index) =>
        line === after[index] ||
        (tag.test(line) && tag.test(after[index])) ||
        (digest.test(line) && digest.test(after[index])),
    )
  );
}

function current(pull, repository, number, head, base) {
  return (
    pull.number === number &&
    pull.state === "open" &&
    pull.draft === false &&
    pull.base?.ref === "master" &&
    pull.base?.sha === base &&
    pull.base?.repo?.full_name === repository &&
    pull.head?.sha === head &&
    pull.head?.repo?.full_name === repository &&
    pull.changed_files === 1 &&
    pull.user?.login === "anovelbot-dependencies[bot]" &&
    pull.user?.type === "Bot"
  );
}

function trustedRun(run, repository, workflowId, path = mainPath) {
  return (
    positiveId(run.id) &&
    run.workflow_id === workflowId &&
    run.path === path &&
    run.repository?.full_name === repository &&
    run.head_repository?.full_name === repository &&
    run.status === "completed" &&
    positiveId(run.run_attempt)
  );
}

async function tree(api, prefix, commit) {
  const result = await api(`${prefix}/git/trees/${commit}?recursive=1`);
  if (result.truncated !== false || !Array.isArray(result.tree))
    throw new Error("The exact commit tree could not be inventoried.");
  return result.tree;
}

function regularBlob(entries, path) {
  const matches = entries.filter((entry) => entry.path === path);
  const entry = matches[0];
  return matches.length === 1 &&
    entry.type === "blob" &&
    entry.mode === "100644" &&
    sha.test(entry.sha) &&
    positiveId(entry.size) &&
    entry.size <= 65536
    ? entry
    : null;
}

async function content(api, prefix, entry) {
  const blob = await api(`${prefix}/git/blobs/${entry.sha}`);
  const bytes = Buffer.from(blob.content ?? "", "base64");
  const hash = createHash("sha1")
    .update(`blob ${bytes.length}\0`)
    .update(bytes)
    .digest("hex");
  if (
    blob.encoding !== "base64" ||
    blob.sha !== entry.sha ||
    blob.size !== entry.size ||
    bytes.length !== entry.size ||
    hash !== entry.sha
  )
    throw new Error("The exact manifest blob could not be verified.");
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

/** Rechecks the exact candidate before the workflow obtains any cloud credentials. */
export async function verifyImageAssessment(
  { repository, number, head, base },
  api = github,
) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository ?? "") ||
    !positiveId(number) ||
    !sha.test(head ?? "") ||
    !sha.test(base ?? "")
  )
    throw new Error("Invalid image-assessment coordinates.");
  const prefix = `repos/${repository}`;
  const pull = await api(`${prefix}/pulls/${number}`);
  if (!current(pull, repository, number, head, base)) return false;
  const files = pages(
    await api(`${prefix}/pulls/${number}/files?per_page=100`, {
      paginate: true,
    }),
  );
  if (
    files.length !== 1 ||
    files[0].filename !== manifestPath ||
    files[0].status !== "modified" ||
    files[0].previous_filename
  )
    return false;
  const before = await tree(api, prefix, base);
  const after = await tree(api, prefix, head);
  const previous = regularBlob(before, manifestPath);
  const next = regularBlob(after, manifestPath);
  const trustedMain = regularBlob(before, mainPath);
  const candidateMain = regularBlob(after, mainPath);
  if (
    !previous ||
    !next ||
    !trustedMain ||
    !candidateMain ||
    candidateMain.sha !== trustedMain.sha
  )
    return false;
  if (
    !imageValuesOnly(
      await content(api, prefix, previous),
      await content(api, prefix, next),
    )
  )
    return false;

  const workflow = await api(`${prefix}/actions/workflows/main.yaml`);
  if (!positiveId(workflow.id) || workflow.path !== mainPath) return false;
  const runs = pages(
    await api(
      `${prefix}/actions/workflows/main.yaml/runs?event=pull_request&head_sha=${head}&per_page=100`,
      {
        paginate: true,
      },
    ),
    "workflow_runs",
  ).filter(
    (run) =>
      run.event === "pull_request" &&
      run.head_sha === head &&
      run.head_branch === pull.head.ref,
  );
  runs.sort((a, b) => b.id - a.id);
  if (!positiveId(runs[0]?.id)) return false;
  const run = await api(`${prefix}/actions/runs/${runs[0].id}`);
  if (
    !trustedRun(run, repository, workflow.id) ||
    run.event !== "pull_request" ||
    run.head_sha !== head ||
    run.head_branch !== pull.head.ref
  )
    return false;
  const jobs = pages(
    await api(
      `${prefix}/actions/runs/${run.id}/jobs?filter=latest&per_page=100`,
      { paginate: true },
    ),
    "jobs",
  );
  if (
    !requiredJobs.every((name) => {
      const matches = jobs.filter((job) => job.name === name);
      return (
        matches.length === 1 &&
        matches[0].run_id === run.id &&
        positiveId(matches[0].run_attempt) &&
        matches[0].run_attempt <= run.run_attempt &&
        matches[0].status === "completed" &&
        matches[0].conclusion === "success"
      );
    })
  )
    return false;

  // A push, close, or base update during validation invalidates the authorization.
  const liveRun = await api(`${prefix}/actions/runs/${run.id}`);
  return (
    liveRun.status === "completed" &&
    liveRun.run_attempt === run.run_attempt &&
    current(
      await api(`${prefix}/pulls/${number}`),
      repository,
      number,
      head,
      base,
    ) &&
    (await api(`${prefix}/git/ref/heads/master`)).object?.sha === base
  );
}

/** Serializes image assessments; each completion considers the remaining open PRs. */
export async function dispatchImageAssessments(
  { repository, event, base },
  api = github,
) {
  if (
    event?.action !== "completed" ||
    event.repository?.full_name !== repository ||
    !positiveId(event.workflow_run?.id) ||
    !sha.test(base ?? "")
  )
    return [];
  const prefix = `repos/${repository}`;
  const run = await api(`${prefix}/actions/runs/${event.workflow_run.id}`);
  const assessmentComplete =
    run.path === driftPath &&
    run.event === "workflow_dispatch" &&
    run.head_branch === "master";
  const path = assessmentComplete ? driftPath : mainPath;
  const workflow = await api(
    `${prefix}/actions/workflows/${assessmentComplete ? "drift" : "main"}.yaml`,
  );
  if (
    !trustedRun(run, repository, workflow.id, path) ||
    workflow.path !== path ||
    !sha.test(run.head_sha)
  )
    return [];
  if (!assessmentComplete && !["push", "pull_request"].includes(run.event))
    return [];
  const master = run.head_branch === "master";
  if (
    !assessmentComplete &&
    master &&
    (run.event !== "push" ||
      run.head_sha !== base ||
      run.conclusion !== "success")
  )
    return [];
  if ((await api(`${prefix}/git/ref/heads/master`)).object?.sha !== base)
    return [];
  const pulls = pages(
    await api(`${prefix}/pulls?state=open&base=master&per_page=100`, {
      paginate: true,
    }),
  );
  const assessments = pages(
    await api(
      `${prefix}/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100`,
      { paginate: true },
    ),
    "workflow_runs",
  );
  // GitHub retains only one pending production run. A completion starts the next assessment.
  if (
    assessments.some((run) =>
      ["queued", "in_progress", "waiting", "pending", "requested"].includes(
        run.status,
      ),
    )
  )
    return [];
  const dispatched = [];
  for (const pull of pulls) {
    if (!positiveId(pull.number) || !sha.test(pull.head?.sha ?? "")) continue;
    const target = {
      repository,
      number: pull.number,
      head: pull.head.sha,
      base,
    };
    const title = `resource-deletion assessment PR #${target.number} ${target.head} onto ${base}`;
    // A failed assessment stays visible for human diagnosis; completion events cannot retry-loop.
    if (
      assessments.some(
        (assessment) =>
          assessment.display_title === title &&
          assessment.path === ".github/workflows/drift.yaml" &&
          assessment.head_sha === base &&
          assessment.event === "workflow_dispatch" &&
          assessment.head_branch === "master",
      )
    )
      continue;
    if (!(await verifyImageAssessment(target, api))) continue;
    await api(`${prefix}/actions/workflows/drift.yaml/dispatches`, {
      method: "POST",
      body: {
        ref: "master",
        inputs: {
          operation: "assess-image-update",
          pull_request: String(target.number),
          head_sha: target.head,
          base_sha: base,
        },
      },
    });
    dispatched.push(target.number);
    break;
  }
  return dispatched;
}

async function main() {
  const repository = process.env.GITHUB_REPOSITORY;
  if (process.argv[2] === "dispatch") {
    if (process.env.GITHUB_EVENT_NAME !== "workflow_run")
      throw new Error("Expected a workflow completion.");
    const base = execFileSync("git", ["rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim();
    const dispatched = await dispatchImageAssessments({
      repository,
      base,
      event: JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")),
    });
    console.log(
      `Requested image assessments: ${dispatched.join(", ") || "none"}.`,
    );
  } else if (process.argv[2] === "verify") {
    if (
      process.env.GITHUB_REF !== "refs/heads/master" ||
      process.env.GITHUB_SHA !== process.env.BASE_SHA ||
      !(await verifyImageAssessment({
        repository,
        number: Number(process.env.PULL_REQUEST),
        head: process.env.HEAD_SHA,
        base: process.env.BASE_SHA,
      }))
    )
      throw new Error(
        "Image update is ineligible, stale, or still awaiting successful PR validation; use maintainer assessment if needed.",
      );
    console.log(
      "Exact Renovate image update authorized for metadata-only assessment.",
    );
  } else throw new Error("Usage: assess-image-updates.mjs dispatch|verify");
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

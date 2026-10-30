// Holds every repository to the settings the GitHub provider cannot manage yet (a-novel/.github#534).
// After each apply, the deploy job and the sweep run it with --apply, which writes back each setting
// that differs; the drift check runs it without, which only warns. Each setting names the follow-up
// issue that replaces its assert with a provider resource.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { github, installationToken } from "./secret-sync.mjs";

/** Each setting: where the repository holds it, how it is written, and the value it keeps. */
export const settings = [
  // a-novel/infra#1242. The scan-secrets and lint jobs do the static analysis, and each organization's
  // default code security configuration turns default setup on for a new repository.
  {
    name: "code scanning default setup",
    endpoint: "/code-scanning/default-setup",
    method: "PATCH",
    field: "state",
    value: "not-configured",
  },
  // a-novel/infra#1243. Code Quality bills per active committer.
  {
    name: "Code Quality",
    endpoint: "/code-quality/setup",
    method: "PATCH",
    field: "state",
    value: "not-configured",
  },
  // a-novel/infra#1244. An outside contributor's fork runs nothing until a maintainer approves it.
  {
    name: "fork pull request approval",
    endpoint: "/actions/permissions/fork-pr-contributor-approval",
    method: "PUT",
    field: "approval_policy",
    value: "all_external_contributors",
  },
  // a-novel/infra#1333. Outsiders use issues and discussions; GitHub Apps count as collaborators.
  {
    name: "pull request creation",
    endpoint: "",
    method: "PATCH",
    field: "pull_request_creation_policy",
    value: "collaborators_only",
  },
];

/**
 * Reads each setting of one repository and, with apply, writes back each one that differs. Returns
 * those that differed, each with the value it held.
 */
export async function assert(request, repository, apply) {
  const live = await Promise.all(
    settings.map((setting) =>
      request("GET", `repos/${repository}${setting.endpoint}`),
    ),
  );
  const drifted = settings
    .map((setting, i) => ({ ...setting, live: live[i][setting.field] }))
    .filter((setting) => setting.live !== setting.value);
  if (apply) {
    for (const { method, endpoint, field, value } of drifted)
      await request(method, `repos/${repository}${endpoint}`, {
        [field]: value,
      });
  }
  return drifted;
}

/** Asserts every repository's settings, and returns whether one differed. */
export async function main(organizations, apply) {
  let differed = false;
  for (const [owner, { project, app, repositories }] of Object.entries(
    organizations,
  )) {
    const token = await installationToken(project, app);
    const request = (method, path, body) => github(token, method, path, body);
    for (const name of repositories) {
      const repository = `${owner}/${name}`;
      for (const setting of await assert(request, repository, apply)) {
        differed = true;
        console.log(
          apply
            ? `${repository}: set ${setting.name} to ${setting.value}, from ${setting.live}.`
            : `::warning::${repository}'s ${setting.name} is ${setting.live}, not ${setting.value}. The GitHub root's next apply resets it.`,
        );
      }
    }
  }
  return differed;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [file, mode] = process.argv.slice(2);
  const apply = mode === "--apply";
  if ((await main(JSON.parse(readFileSync(file, "utf8")), apply)) && !apply)
    process.exitCode = 1;
}

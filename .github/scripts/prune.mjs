// Prunes the rulesets and deployment patterns the GitHub root does not produce (a-novel/.github#534).
// It keeps every object whose ID OpenTofu knows, read from what `tofu show -json` prints: a plan's
// prior and planned state, or the state after an apply. It reads deployment patterns only in the
// environments the root manages, so GitHub's own, such as github-pages, and infra's deploy
// environments keep theirs. Environments are never pruned, and secret sync prunes governance secrets.
//
// Modes: check lists what it would delete and fails when there is any; report only lists, for a
// pull request carrying allow-resource-deletion; apply deletes, for a deploy that label approved.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { github, installationToken } from "./secret-sync.mjs";

/** The IDs of the rulesets and deployment policies in a `tofu show -json` document. */
export function known(show) {
  const keep = { rulesets: new Set(), policies: new Set() };
  const modules = [show.values, show.prior_state?.values, show.planned_values]
    .filter(Boolean)
    .map((values) => values.root_module);
  while (modules.length > 0) {
    const module = modules.pop();
    modules.push(...(module.child_modules ?? []));
    for (const { type, values } of module.resources ?? []) {
      // A resource the plan creates has no ID yet, and nothing live can carry it.
      if (type === "github_repository_ruleset" && values.ruleset_id)
        keep.rulesets.add(values.ruleset_id);
      if (
        type === "github_repository_environment_deployment_policy" &&
        values.policy_id
      )
        keep.policies.add(values.policy_id);
    }
  }
  return keep;
}

// A repository or environment the plan creates does not exist yet, and holds nothing to prune.
async function list(request, path) {
  try {
    return await request("GET", path);
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

/**
 * The objects of one organization that OpenTofu does not know, deleted with apply. Each has a
 * description for the log.
 */
export async function prune(request, owner, organization, keep, apply) {
  const strays = [];
  for (const name of organization.repositories) {
    const rulesets = await list(
      request,
      `repos/${owner}/${name}/rulesets?includes_parents=false&per_page=100`,
    );
    for (const { id, name: ruleset, source_type } of rulesets ?? []) {
      if (source_type !== "Repository" || keep.rulesets.has(id)) continue;
      strays.push({
        path: `repos/${owner}/${name}/rulesets/${id}`,
        description: `${owner}/${name}'s ruleset ${ruleset}`,
      });
    }
  }
  for (const key of organization.environments) {
    const [name, environment] = key.split(":");
    const path = `repos/${owner}/${name}/environments/${environment}/deployment-branch-policies`;
    const policies = await list(request, `${path}?per_page=100`);
    for (const { id, name: pattern, type } of policies?.branch_policies ?? []) {
      if (keep.policies.has(id)) continue;
      strays.push({
        path: `${path}/${id}`,
        description: `${owner}/${name}'s ${environment} ${type} pattern ${pattern}`,
      });
    }
  }
  if (apply) {
    for (const { path } of strays) await request("DELETE", path);
  }
  return strays;
}

/** Prunes both organizations as app, and returns how many objects it found. */
export async function main(show, app, mode) {
  const keep = known(show);
  // Every ready repository holds rulesets, so an empty keep-list means the wrong document, which
  // would make every ruleset a stray.
  if (keep.rulesets.size === 0)
    throw new Error(
      "The document names no ruleset; prune would delete them all.",
    );
  const organizations = (show.values ?? show.planned_values).outputs
    .organizations.value;
  let found = 0;
  for (const [owner, organization] of Object.entries(organizations)) {
    const token = await installationToken(
      organization.project,
      organization.apps[app],
    );
    const request = (method, path) => github(token, method, path);
    for (const { description } of await prune(
      request,
      owner,
      organization,
      keep,
      mode === "apply",
    )) {
      found++;
      console.log(
        mode === "apply"
          ? `Deleted ${description}.`
          : `::warning::Prune would delete ${description}, which the GitHub root does not produce.`,
      );
    }
  }
  return found;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [file, app, mode] = process.argv.slice(2);
  if (
    !["plan", "deploy"].includes(app) ||
    !["check", "report", "apply"].includes(mode)
  )
    throw new Error(
      "usage: prune.mjs <tofu show -json> <plan|deploy> <check|report|apply>",
    );
  const found = await main(JSON.parse(readFileSync(file, "utf8")), app, mode);
  if (found > 0 && mode === "check") {
    console.log(
      `::error::Prune deletes what the GitHub root does not produce only with the allow-resource-deletion label.`,
    );
    process.exitCode = 1;
  }
}

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { known, main, prune } from "./prune.mjs";

const ruleset = (ruleset_id) => ({
  type: "github_repository_ruleset",
  values: { ruleset_id },
});
const policy = (policy_id) => ({
  type: "github_repository_environment_deployment_policy",
  values: { policy_id },
});

describe("known", () => {
  it("keeps every ID a plan's prior or planned state holds, in every module", () => {
    const keep = known({
      prior_state: {
        values: {
          root_module: {
            child_modules: [{ resources: [ruleset(1), policy(10)] }],
          },
        },
      },
      planned_values: {
        root_module: {
          child_modules: [
            { resources: [ruleset(2), ruleset(undefined), policy(11)] },
          ],
        },
      },
    });

    assert.deepEqual([...keep.rulesets].sort(), [1, 2]);
    assert.deepEqual([...keep.policies].sort(), [10, 11]);
  });

  it("reads a state's IDs", () => {
    const keep = known({
      values: { root_module: { child_modules: [{ resources: [ruleset(3)] }] } },
    });

    assert.deepEqual([...keep.rulesets], [3]);
  });
});

// One organization: infra holds a managed ruleset, a stray one and an organization ruleset; its
// governance environment holds a managed pattern and a stray one; the release environment is new.
function organization() {
  const calls = [];
  const responses = {
    "repos/a-novel/infra/rulesets?includes_parents=false&per_page=100": [
      { id: 1, name: "master", source_type: "Repository" },
      { id: 2, name: "by-hand", source_type: "Repository" },
      { id: 3, name: "org-wide", source_type: "Organization" },
    ],
    "repos/a-novel/infra/environments/governance/deployment-branch-policies?per_page=100":
      {
        branch_policies: [
          { id: 10, name: "master", type: "branch" },
          { id: 11, name: "feature/*", type: "branch" },
        ],
      },
  };
  const request = async (method, path) => {
    calls.push([method, path]);
    if (method !== "GET") return null;
    if (!(path in responses))
      throw Object.assign(new Error("Not Found"), { status: 404 });
    return responses[path];
  };
  return {
    calls,
    request,
    organization: {
      repositories: ["infra"],
      environments: ["infra:governance", "infra:release"],
    },
  };
}

const keep = { rulesets: new Set([1]), policies: new Set([10]) };

describe("prune", () => {
  it("lists what OpenTofu does not know, in the managed environments only, and deletes nothing", async () => {
    const { calls, request, organization: org } = organization();

    const strays = await prune(request, "a-novel", org, keep, false);
    assert.deepEqual(
      strays.map(({ description }) => description),
      [
        "a-novel/infra's ruleset by-hand",
        "a-novel/infra's governance branch pattern feature/*",
      ],
    );
    assert.ok(calls.every(([method]) => method === "GET"));
    assert.equal(calls.length, 3);
  });

  it("deletes exactly those with apply", async () => {
    const { calls, request, organization: org } = organization();

    await prune(request, "a-novel", org, keep, true);
    assert.deepEqual(
      calls.filter(([method]) => method === "DELETE"),
      [
        ["DELETE", "repos/a-novel/infra/rulesets/2"],
        [
          "DELETE",
          "repos/a-novel/infra/environments/governance/deployment-branch-policies/11",
        ],
      ],
    );
  });

  it("stops on any error but a missing repository or environment", async () => {
    const request = async () => {
      throw Object.assign(new Error("Forbidden"), { status: 403 });
    };

    await assert.rejects(
      prune(request, "a-novel", organization().organization, keep, false),
      /Forbidden/,
    );
  });
});

describe("main", () => {
  it("refuses a document that names no ruleset", async () => {
    await assert.rejects(
      main(
        {
          values: {
            root_module: {},
            outputs: { organizations: { value: {} } },
          },
        },
        "plan",
        "check",
      ),
      /names no ruleset/,
    );
  });
});

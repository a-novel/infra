import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { failedSources, tokenJobs } from "./rerun-failed-jobs.mjs";

// The shape tofu show -json gives a plan: configuration addresses are relative to their module,
// prior-state addresses are absolute and carry instance keys.
const job = (address, name, token) => ({
  address,
  type: "google_cloud_run_v2_job",
  values: {
    name,
    location: "europe-west1",
    project: "a-novel-production-prod",
    run_execution_token: token,
  },
});
const plan = {
  configuration: {
    root_module: {
      resources: [
        {
          address: "google_cloud_run_v2_job.application",
          type: "google_cloud_run_v2_job",
          expressions: {
            run_execution_token: {
              references: [
                "each.key",
                "terraform_data.migrations.id",
                "terraform_data.migrations",
              ],
            },
          },
        },
        {
          address: "google_cloud_run_v2_job.sweep",
          type: "google_cloud_run_v2_job",
          expressions: {},
        },
      ],
      module_calls: {
        smoke: {
          module: {
            resources: [
              {
                address: "google_cloud_run_v2_job.smoke",
                type: "google_cloud_run_v2_job",
                expressions: {
                  run_execution_token: {
                    references: [
                      "terraform_data.smoke.id",
                      "terraform_data.smoke",
                    ],
                  },
                },
              },
            ],
          },
        },
      },
    },
  },
  prior_state: {
    values: {
      root_module: {
        resources: [
          job(
            'google_cloud_run_v2_job.application["migrations"]',
            "agora-json-keys-migrations",
            "a1",
          ),
          job(
            'google_cloud_run_v2_job.application["rotatekeys"]',
            "agora-json-keys-rotatekeys",
            null,
          ),
          job("google_cloud_run_v2_job.sweep", "agora-genai-sweep", null),
        ],
        child_modules: [
          {
            address: "module.smoke",
            resources: [
              job(
                "module.smoke.google_cloud_run_v2_job.smoke",
                "agora-json-keys-smoke",
                "b2",
              ),
            ],
          },
        ],
      },
    },
  },
};

describe("tokenJobs", () => {
  it("finds every job a token runs, with the terraform_data its token derives from", () => {
    assert.deepEqual(
      tokenJobs(plan).map(({ source, name }) => [source, name]),
      [
        ["terraform_data.migrations", "agora-json-keys-migrations"],
        ["module.smoke.terraform_data.smoke", "agora-json-keys-smoke"],
      ],
    );
  });

  it("finds nothing in a plan with no prior state", () => {
    assert.deepEqual(tokenJobs({ configuration: plan.configuration }), []);
  });
});

describe("failedSources", () => {
  const jobs = tokenJobs(plan);
  const run = (statuses) =>
    failedSources(jobs, async ({ source }) => statuses[source] ?? null);

  it("runs again a job whose last execution failed or was cancelled", async () => {
    assert.deepEqual(
      await run({ "terraform_data.migrations": "EXECUTION_FAILED" }),
      ["terraform_data.migrations"],
    );
    assert.deepEqual(
      await run({ "module.smoke.terraform_data.smoke": "EXECUTION_CANCELLED" }),
      ["module.smoke.terraform_data.smoke"],
    );
  });

  it("leaves a succeeded, running or unreadable execution alone", async () => {
    assert.deepEqual(
      await run({
        "terraform_data.migrations": "EXECUTION_SUCCEEDED",
        "module.smoke.terraform_data.smoke": "EXECUTION_RUNNING",
      }),
      [],
    );
    assert.deepEqual(await run({}), []);
  });
});

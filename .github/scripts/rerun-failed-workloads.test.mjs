import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { failedSources, tokenWorkloads } from "./rerun-failed-workloads.mjs";

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
const service = (address, name, condition) => ({
  address,
  type: "google_cloud_run_v2_service",
  values: { name, terminal_condition: condition ? [{ state: condition }] : [] },
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
        {
          address: "google_cloud_run_v2_service.grpc",
          type: "google_cloud_run_v2_service",
          expressions: {
            template: [
              {
                annotations: {
                  references: [
                    "terraform_data.grpc_revision.id",
                    "terraform_data.grpc_revision",
                  ],
                },
              },
            ],
          },
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
          service(
            "google_cloud_run_v2_service.grpc",
            "agora-json-keys-grpc",
            "CONDITION_FAILED",
          ),
          service(
            "data.google_cloud_run_v2_service.json_keys",
            "agora-json-keys-grpc",
            "CONDITION_SUCCEEDED",
          ),
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

describe("tokenWorkloads", () => {
  it("finds every job and service a token starts, with the terraform_data its token derives from", () => {
    assert.deepEqual(
      tokenWorkloads(plan).map(({ source, name }) => [source, name]),
      [
        ["terraform_data.migrations", "agora-json-keys-migrations"],
        ["terraform_data.grpc_revision", "agora-json-keys-grpc"],
        ["module.smoke.terraform_data.smoke", "agora-json-keys-smoke"],
      ],
    );
  });

  it("reads a service's status from its refreshed terminal condition", () => {
    const status = (condition) =>
      tokenWorkloads({
        ...plan,
        prior_state: {
          values: {
            root_module: {
              resources: [
                service(
                  "google_cloud_run_v2_service.grpc",
                  "agora-json-keys-grpc",
                  condition,
                ),
              ],
            },
          },
        },
      })[0].status;
    assert.equal(status("CONDITION_FAILED"), "CONDITION_FAILED");
    assert.equal(status(null), null);
  });

  it("finds nothing in a plan with no prior state", () => {
    assert.deepEqual(tokenWorkloads({ configuration: plan.configuration }), []);
  });

  it("follows a module that another module calls", () => {
    const smoke = plan.configuration.root_module.module_calls.smoke.module;
    const nested = {
      configuration: {
        root_module: {
          module_calls: {
            outer: { module: { module_calls: { inner: { module: smoke } } } },
          },
        },
      },
      prior_state: {
        values: {
          root_module: {
            child_modules: [
              {
                address: "module.outer",
                child_modules: [
                  {
                    address: "module.outer.module.inner",
                    resources: [
                      job(
                        "module.outer.module.inner.google_cloud_run_v2_job.smoke",
                        "agora-nested-smoke",
                        "c3",
                      ),
                    ],
                  },
                ],
              },
            ],
          },
        },
      },
    };
    assert.deepEqual(
      tokenWorkloads(nested).map(({ source, name }) => [source, name]),
      [
        [
          "module.outer.module.inner.terraform_data.smoke",
          "agora-nested-smoke",
        ],
      ],
    );
  });
});

describe("failedSources", () => {
  const workloads = tokenWorkloads(plan);
  const run = (statuses) =>
    failedSources(workloads, async ({ source }) => statuses[source] ?? null);

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

  it("rolls again a service whose last rollout failed", async () => {
    assert.deepEqual(
      await run({ "terraform_data.grpc_revision": "CONDITION_FAILED" }),
      ["terraform_data.grpc_revision"],
    );
  });

  it("leaves a succeeded, running or unreadable workload alone", async () => {
    assert.deepEqual(
      await run({
        "terraform_data.migrations": "EXECUTION_SUCCEEDED",
        "module.smoke.terraform_data.smoke": "EXECUTION_RUNNING",
        "terraform_data.grpc_revision": "CONDITION_RECONCILING",
      }),
      [],
    );
    assert.deepEqual(
      await run({ "terraform_data.grpc_revision": "CONDITION_SUCCEEDED" }),
      [],
    );
    assert.deepEqual(await run({}), []);
  });
});

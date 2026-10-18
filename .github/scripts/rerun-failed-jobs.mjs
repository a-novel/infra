// Which job executions a plan must start again. A Cloud Run job run through run_execution_token
// records its new token even when the execution fails, so the next plan shows nothing to do: a
// failed migration would never run again, and the services would deploy against the old schema.
// Replacing the terraform_data the token derives from gives the job a new token, so it runs again.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const unindexed = (address) => address.replace(/\[[^\]]*\]/g, "");

/**
 * Every job in the plan's prior state that a token runs, with the terraform_data address its
 * run_execution_token derives from.
 */
export function tokenJobs(plan) {
  const sources = new Map();
  const configure = (module, prefix) => {
    for (const resource of module.resources ?? []) {
      const source =
        resource.expressions?.run_execution_token?.references?.find((ref) =>
          /^terraform_data\.[^.]+$/.test(ref),
        );
      if (resource.type === "google_cloud_run_v2_job" && source) {
        sources.set(prefix + resource.address, prefix + source);
      }
    }
    for (const [name, call] of Object.entries(module.module_calls ?? {})) {
      configure(call.module, `${prefix}module.${name}.`);
    }
  };
  configure(plan.configuration?.root_module ?? {}, "");

  const jobs = [];
  const walk = (module) => {
    for (const resource of module.resources ?? []) {
      const source = sources.get(unindexed(resource.address));
      const { name, location, project, run_execution_token } =
        resource.values ?? {};
      if (source && run_execution_token)
        jobs.push({ source, name, location, project });
    }
    for (const child of module.child_modules ?? []) walk(child);
  };
  walk(plan.prior_state?.values?.root_module ?? {});
  return jobs;
}

/**
 * The token sources of the jobs whose last execution failed or was cancelled. A status that could
 * not be read starts nothing: the plan then behaves as it did before this check.
 */
export async function failedSources(jobs, statusOf, log = () => {}) {
  const sources = new Set();
  for (const job of jobs) {
    const status = await statusOf(job);
    log(`${job.name}: last execution ${status ?? "unknown"}`);
    if (["EXECUTION_FAILED", "EXECUTION_CANCELLED"].includes(status))
      sources.add(job.source);
  }
  return [...sources];
}

async function main([planPath], { ACCESS_TOKEN }) {
  const plan = JSON.parse(readFileSync(planPath, "utf8"));
  const statusOf = async ({ name, location, project }) => {
    try {
      const response = await fetch(
        `https://run.googleapis.com/v2/projects/${project}/locations/${location}/jobs/${name}`,
        { headers: { Authorization: `Bearer ${ACCESS_TOKEN}` } },
      );
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return (
        (await response.json()).latestCreatedExecution?.completionStatus ?? null
      );
    } catch (error) {
      console.error(
        `::warning::Could not read the last execution of ${name}: ${error.message}.`,
      );
      return null;
    }
  };
  // stdout carries only the sources; the statuses go to the log.
  for (const source of await failedSources(
    tokenJobs(plan),
    statusOf,
    console.error,
  ))
    console.log(source);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2), process.env).catch((error) => {
    console.error(`::error::${error.message}`);
    process.exit(1);
  });
}

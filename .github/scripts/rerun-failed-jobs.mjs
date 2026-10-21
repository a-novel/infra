// Which job executions a plan must start again. A Cloud Run job run through run_execution_token
// records its new token even when the execution fails, so the next plan shows nothing to do: a
// failed migration would never run again, and the services would deploy against the old schema.
// Replacing the terraform_data the token derives from gives the job a new token, so it runs again.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const unindexed = (address) => address.replace(/\[[^\]]*\]/g, "");
const isTerraformData = (reference) =>
  /^terraform_data\.[^.]+$/.test(reference);

/**
 * Every job in the plan's prior state that a token runs, with the terraform_data address its
 * run_execution_token derives from.
 */
export function tokenJobs(plan) {
  const sources = new Map(tokenSources(plan.configuration?.root_module ?? {}));
  const state = plan.prior_state?.values?.root_module ?? {};
  const jobs = [];
  for (const resource of resources(state)) {
    const source = sources.get(unindexed(resource.address));
    const { name, location, project, run_execution_token } =
      resource.values ?? {};
    if (source && run_execution_token)
      jobs.push({ source, name, location, project });
  }
  return jobs;
}

/**
 * Yields [job, source] address pairs for each configured job whose token derives from a
 * terraform_data. The loop also visits each module call it appends.
 */
function* tokenSources(root) {
  const modules = [{ module: root, prefix: "" }];
  for (const { module, prefix } of modules) {
    for (const resource of module.resources ?? []) {
      const source =
        resource.expressions?.run_execution_token?.references?.find(
          isTerraformData,
        );
      if (resource.type === "google_cloud_run_v2_job" && source) {
        yield [prefix + resource.address, prefix + source];
      }
    }
    for (const [name, call] of Object.entries(module.module_calls ?? {})) {
      modules.push({ module: call.module, prefix: `${prefix}module.${name}.` });
    }
  }
}

/** Yields every resource of a state module and of its child modules, which the loop appends. */
function* resources(root) {
  const modules = [root];
  for (const module of modules) {
    yield* module.resources ?? [];
    modules.push(...(module.child_modules ?? []));
  }
}

/**
 * The token sources of the jobs whose last execution failed or was cancelled. The statuses are read
 * together. A status that cannot be read starts nothing, and the plan runs unchanged.
 */
export async function failedSources(jobs, statusOf, log = () => {}) {
  const statuses = await Promise.all(jobs.map((job) => statusOf(job)));
  const sources = new Set();
  for (const [index, job] of jobs.entries()) {
    log(`${job.name}: last execution ${statuses[index] ?? "unknown"}`);
    if (["EXECUTION_FAILED", "EXECUTION_CANCELLED"].includes(statuses[index]))
      sources.add(job.source);
  }
  return [...sources];
}

/** The completion status of a job's last execution, or null when it cannot be read. */
async function lastStatus({ name, location, project }, accessToken) {
  try {
    const response = await fetch(
      `https://run.googleapis.com/v2/projects/${project}/locations/${location}/jobs/${name}`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
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
}

async function main([planPath], { ACCESS_TOKEN }) {
  const plan = JSON.parse(readFileSync(planPath, "utf8"));
  const statusOf = (job) => lastStatus(job, ACCESS_TOKEN);
  const sources = await failedSources(tokenJobs(plan), statusOf, console.error);
  // stdout carries only the sources; the statuses go to the log.
  for (const source of sources) console.log(source);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await main(process.argv.slice(2), process.env);
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exit(1);
  }
}

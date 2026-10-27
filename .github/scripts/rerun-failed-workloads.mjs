// Which workloads a plan must start again. A Cloud Run job run through run_execution_token records
// its new token even when the execution fails, so the next plan shows nothing to do: a failed
// migration would never run again, and the services would deploy against the old schema. A Cloud
// Run service likewise records its new template when the revision fails to start, and keeps serving
// the previous one. Replacing the terraform_data a token derives from gives the workload a new
// token, so the job runs again and the service rolls again.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const unindexed = (address) => address.replace(/\[[^\]]*\]/g, "");
const isTerraformData = (reference) =>
  /^terraform_data\.[^.]+$/.test(reference);

// A job's execution that failed or was cancelled, and a service's rollout that failed. A service
// still reconciling has not finished its rollout, so it is left alone.
const failures = new Set([
  "EXECUTION_FAILED",
  "EXECUTION_CANCELLED",
  "CONDITION_FAILED",
]);

/**
 * Every workload in the plan's prior state that a token starts, with the terraform_data address
 * its token derives from. A service also carries its status, the refreshed state of its last
 * rollout.
 */
export function tokenWorkloads(plan) {
  const sources = new Map(tokenSources(plan.configuration?.root_module ?? {}));
  const state = plan.prior_state?.values?.root_module ?? {};
  const workloads = [];
  for (const resource of resources(state)) {
    const source = sources.get(unindexed(resource.address));
    const { name, location, project, run_execution_token, terminal_condition } =
      resource.values ?? {};
    if (!source) continue;
    if (resource.type === "google_cloud_run_v2_service") {
      workloads.push({
        source,
        name,
        status: terminal_condition?.[0]?.state ?? null,
      });
    } else if (run_execution_token) {
      workloads.push({ source, name, location, project });
    }
  }
  return workloads;
}

/**
 * The expression a workload sets its token in: a job's run_execution_token, a service's template
 * annotations.
 */
function tokenExpression({ type, expressions = {} }) {
  if (type === "google_cloud_run_v2_job")
    return expressions.run_execution_token;
  if (type === "google_cloud_run_v2_service")
    return expressions.template?.[0]?.annotations;
}

/**
 * Yields [workload, source] address pairs for each configured workload whose token derives from a
 * terraform_data. The loop also visits each module call it appends.
 */
function* tokenSources(root) {
  const modules = [{ module: root, prefix: "" }];
  for (const { module, prefix } of modules) {
    for (const resource of module.resources ?? []) {
      const source =
        tokenExpression(resource)?.references?.find(isTerraformData);
      if (source) yield [prefix + resource.address, prefix + source];
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
 * The token sources of the workloads whose last execution or rollout failed. The statuses are read
 * together. A status that cannot be read starts nothing, and the plan runs unchanged.
 */
export async function failedSources(workloads, statusOf, log = () => {}) {
  const statuses = await Promise.all(
    workloads.map((workload) => statusOf(workload)),
  );
  const sources = new Set();
  for (const [index, workload] of workloads.entries()) {
    log(`${workload.name}: ${statuses[index] ?? "unknown"}`);
    if (failures.has(statuses[index])) sources.add(workload.source);
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
  // The plan refreshed each service's status; a job's last execution is read from Cloud Run.
  const statusOf = (workload) =>
    "status" in workload ? workload.status : lastStatus(workload, ACCESS_TOKEN);
  const sources = await failedSources(
    tokenWorkloads(plan),
    statusOf,
    console.error,
  );
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

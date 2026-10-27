// Records in Sentry the production deploy of each release a service root serves, once per release.
// Release CI creates each release, named <repository>@<version>, when it cuts the tag. This runs
// only once the root's tofu step succeeded, so every Cloud Run service serves its configuration:
// the apply waits for each service it changes, and the plan rolls a failed one again. Nothing here
// fails the deploy: Sentry problems warn, and the next deploy records what this one missed.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** The releases a root's plan pins, one <repository>@<version> per release, sorted. */
export function releases(plan) {
  const names = new Set();
  for (const { source, producer, workflow } of plan.planned_values?.outputs
    ?.image_copies?.value ?? []) {
    // Only an image its producer's release.yaml built belongs to a release.
    if ((workflow ?? "release.yaml") !== "release.yaml") continue;
    const tag = source.slice(0, source.lastIndexOf("@")).replace(/.*:/, "");
    names.add(`${producer.split("/")[1]}@${tag.replace(/^v/, "")}`);
  }
  return [...names].sort();
}

/**
 * The organization API an organization auth token names. Such a token reads
 * sntrys_<base64 JSON claims>_<secret>, and its claims name the organization and its region.
 */
export function organizationApi(token) {
  const claims = JSON.parse(
    Buffer.from(token.split("_")[1] ?? "", "base64").toString(),
  );
  const host = (claims.region_url || claims.url).replace(/\/+$/, "");
  return `${host}/api/0/organizations/${claims.org}`;
}

/**
 * Records a production deploy for each release that has none. request(method, path, body) calls
 * the organization API and returns the fetch Response; a release Sentry lacks, or a failed call,
 * logs a warning and moves on.
 */
export async function record(names, request, log = console.log) {
  for (const name of names) {
    const path = `/releases/${encodeURIComponent(name)}/deploys/`;
    try {
      const listed = await request("GET", path);
      if (listed.status === 404) {
        log(
          `::warning::Sentry has no release ${name}, so it records no deploy.`,
        );
        continue;
      }
      if (!listed.ok)
        throw new Error(`listing its deploys: HTTP ${listed.status}`);
      const deploys = await listed.json();
      if (deploys.some((deploy) => deploy.environment === "production")) {
        log(`${name} already has a production deploy.`);
        continue;
      }
      const created = await request("POST", path, {
        environment: "production",
        projects: [name.slice(0, name.lastIndexOf("@"))],
      });
      if (!created.ok)
        throw new Error(`recording the deploy: HTTP ${created.status}`);
      log(`Recorded the production deploy of ${name}.`);
    } catch (error) {
      log(`::warning::Sentry deploy of ${name}: ${error.message}.`);
    }
  }
}

async function main([planPath], { SENTRY_AUTH_TOKEN }) {
  if (!SENTRY_AUTH_TOKEN) {
    console.log(
      "::warning::No SENTRY_AUTH_TOKEN, so Sentry records no deploy.",
    );
    return;
  }
  const plan = JSON.parse(readFileSync(planPath, "utf8"));
  const names = releases(plan);
  if (names.length === 0) return;
  const api = organizationApi(SENTRY_AUTH_TOKEN);
  const request = (method, path, body) =>
    fetch(api + path, {
      method,
      headers: {
        Authorization: `Bearer ${SENTRY_AUTH_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: body && JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
  await record(names, request);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await main(process.argv.slice(2), process.env);
  } catch (error) {
    console.log(`::warning::Sentry deploys: ${error.message}`);
  }
}

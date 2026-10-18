// Release provenance of the images a plan copies. A release image deploys only from an immutable
// Release the release App published, built by that tag's own run, and never below the version
// already deployed: pull requests only move forward. Any other image must come from its producer's
// workflow on master. The pins the last apply deployed, the output's value before this plan, were
// verified when they deployed; the plan's prior state already shows the new outputs.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { newest } from "./versions.mjs";

/** The checks a plan's image copies need, one per new source; throws for a lowered release. */
export function checks(plan) {
  const deployed = (plan.output_changes?.image_copies?.before ?? []).map(
    (image) => image.source,
  );
  // The first copy of each source speaks for the others, which name the same producer.
  const sources = new Map();
  for (const image of plan.planned_values?.outputs?.image_copies?.value ?? []) {
    if (!sources.has(image.source)) sources.set(image.source, image);
  }
  return [...sources.keys()]
    .sort()
    .filter((source) => !deployed.includes(source))
    .map((source) => {
      const { producer } = sources.get(source);
      const workflow = sources.get(source).workflow ?? "release.yaml";
      const name = source.slice(0, source.indexOf(":"));
      const reference = source.slice(0, source.lastIndexOf("@"));
      const check = {
        source,
        subject: `oci://${name}@${source.slice(source.lastIndexOf("@") + 1)}`,
        producer,
        workflow,
        tag: reference.slice(reference.lastIndexOf(":") + 1),
      };
      if (workflow !== "release.yaml") return check;
      const previous = newest(
        ...deployed
          .filter((other) => other.startsWith(`${name}:`))
          .map((other) => other.replace(/@.*/, "").replace(/.*:/, "")),
      );
      if (previous && newest(previous, check.tag) !== check.tag) {
        throw new Error(
          `${source} lowers ${name} from ${previous}. Pull requests only move forward: ship the fix as a new release.`,
        );
      }
      return check;
    });
}

// A failure's message carries the command's stderr.
const gh = (...args) =>
  execFileSync("gh", args, { encoding: "utf8", stdio: "pipe" }).trim();

function verify({ source, subject, producer, workflow, tag }, releaseBot) {
  const release = workflow === "release.yaml";
  gh(
    "attestation",
    "verify",
    subject,
    "--repo",
    producer,
    "--signer-workflow",
    `${producer}/.github/workflows/${workflow}`,
    "--source-ref",
    release ? `refs/tags/${tag}` : "refs/heads/master",
    "--deny-self-hosted-runners",
  );
  if (!release) return;
  if (!releaseBot) throw new Error("RELEASE_BOT_LOGIN is not set.");
  const published = gh(
    "api",
    `repos/${producer}/releases/tags/${tag}`,
    "--jq",
    String.raw`"\(.author.login) \(.immutable)"`,
  );
  if (published !== `${releaseBot} true`) {
    throw new Error(
      `${source}: ${producer} ${tag} is not an immutable Release that ${releaseBot} published (got "${published}").`,
    );
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const plan = JSON.parse(readFileSync(process.argv[2], "utf8"));
    for (const check of checks(plan))
      verify(check, process.env.RELEASE_BOT_LOGIN);
  } catch (error) {
    console.log(`::error::${error.message}`);
    process.exit(1);
  }
}

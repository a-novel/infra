// Whether a deploy may delete or unprotect resources: some pull request it ships carried the
// allow-resource-deletion label when it merged, last applied by a maintainer, an admin or the
// Agent App. review-gate holds a label to the same rule before the merge; this reads the label as
// it stood at the merge, so one added afterwards counts for nothing.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const label = "allow-resource-deletion";

/**
 * Whether the label was on the pull request when it merged, applied last by a trusted actor.
 * events is the pull request's issue events, oldest first; trusted decides for an actor.
 */
export function approvedAtMerge(events, mergedAt, trusted) {
  const last = events.filter((event) => changesLabel(event, mergedAt)).at(-1);
  return last?.event === "labeled" && trusted(last.actor);
}

/** Whether an issue event added or removed the label by mergedAt. */
function changesLabel(event, mergedAt) {
  return (
    ["labeled", "unlabeled"].includes(event.event) &&
    event.label?.name === label &&
    event.created_at <= mergedAt
  );
}

// A failure's message carries the command's stderr.
const gh = (...args) =>
  JSON.parse(
    execFileSync("gh", ["api", ...args], { encoding: "utf8", stdio: "pipe" }),
  );

/** The login's role on the repository, or "" for someone outside it. */
function role(repository, login) {
  try {
    return gh(`repos/${repository}/collaborators/${login}/permission`)
      .role_name;
  } catch (error) {
    if (!String(error.stderr).includes("HTTP 404")) throw error;
    return "";
  }
}

function main(commits, { REPOSITORY, AGENT_BOT_LOGIN }) {
  const roles = new Map();
  const trusted = ({ login, type }) => {
    if (type === "Bot") return login === AGENT_BOT_LOGIN;
    if (!roles.has(login)) roles.set(login, role(REPOSITORY, login));
    return ["admin", "maintain"].includes(roles.get(login));
  };
  for (const sha of commits) {
    for (const pr of gh(`repos/${REPOSITORY}/commits/${sha}/pulls`)) {
      if (!pr.merged_at) continue;
      const events = gh(
        "--paginate",
        "--slurp",
        `repos/${REPOSITORY}/issues/${pr.number}/events`,
      ).flat();
      if (approvedAtMerge(events, pr.merged_at, trusted)) return true;
    }
  }
  return false;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    console.log(main(process.argv.slice(2), process.env));
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exit(1);
  }
}

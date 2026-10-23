// Opens, updates or closes the one pull request that refreshes Google's service ranges, once the
// google-service-ranges action has rewritten the file. The Dependencies App opens it, and the strict
// auto-approver approves it only when it holds exactly what Google publishes, so it merges alone.
import { appendFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { commitChanges, gh, moveBranch, run } from "./pin-release.mjs";

const file = "environments/production/foundation/google-service-ranges.json";
const branch = "chore/deps/google-service-ranges";
const title = "chore(deps): refresh Google's service ranges";
const body =
  "Sets the `google-services` address group to Google's current service ranges: `goog.json` minus `cloud.json`. The auto-approver recomputes the list and approves only an exact match.";

/**
 * What the refresh pull request needs, from the list on master, Google's latest, and the one the
 * pull request proposes (undefined without one): "close" it once master holds the latest, "keep"
 * it while it proposes the latest, "push" the latest to it, or "none".
 */
export function next({ master, latest, proposed }) {
  if (latest === master) return proposed === undefined ? "none" : "close";
  return latest === proposed ? "keep" : "push";
}

// Each side as compact JSON, so formatting never reads as a change.
const list = (text) => JSON.stringify(JSON.parse(text));

function main({ GH_REPO, APP, GITHUB_STEP_SUMMARY }) {
  const pr = gh(
    "pr",
    "list",
    "--head",
    branch,
    "--app",
    APP,
    "--json",
    "number",
    "--jq",
    ".[0].number // empty",
  );
  const proposed = pr
    ? list(
        gh(
          "api",
          `repos/${GH_REPO}/contents/${file}?ref=${branch}`,
          "-H",
          "Accept: application/vnd.github.raw+json",
        ),
      )
    : undefined;
  const action = next({
    master: list(run("git", ["show", `HEAD:${file}`])),
    latest: list(readFileSync(file, "utf8")),
    proposed,
  });

  let result = "master already holds Google's current service ranges.";
  if (action === "close")
    gh("pr", "close", pr, "--delete-branch", "--comment", result);
  if (action === "keep")
    result = `#${pr} already proposes Google's current service ranges.`;
  if (action === "push") {
    moveBranch(GH_REPO, branch, commitChanges(GH_REPO, title));
    result = pr
      ? gh("pr", "edit", pr, "--title", title, "--body", body)
      : gh(
          "pr",
          "create",
          "--head",
          branch,
          "--title",
          title,
          "--body",
          body,
          "--label",
          "dependencies",
        );
  }
  console.log(result);
  appendFileSync(GITHUB_STEP_SUMMARY, `${result}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.env);
  } catch (error) {
    console.log(`::error::${error.message}`);
    process.exit(1);
  }
}

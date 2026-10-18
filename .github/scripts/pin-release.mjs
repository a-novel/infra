// Pins every image of a service or platform release in one pull request per repository, opened as
// the Dependencies App, and rebuilds the release pull requests a merge left conflicting. The
// version rules and the rewrite are pure functions; main runs git, gh and skopeo around them.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { isRelease, newest, semver } from "./versions.mjs";

const paths = [
  ":(glob)environments/production/*/terraform.tfvars",
  ":(glob)builds/*.Dockerfile",
];
const titlePattern = new RegExp(
  String.raw`^chore\(deps\): update [a-z0-9-]+ images to (${semver})$`,
);
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

/** The release a pin pull request's head commit names, or "". */
export const branchVersion = (message) =>
  titlePattern.exec(message.split("\n")[0])?.[1] ?? "";

/** Every reference to an image of source in content, as [image name, version] pairs. */
export function pins(content, source) {
  const pattern = new RegExp(
    String.raw`ghcr\.io/${escape(source)}(?:/[a-z0-9._/-]+)?:${semver}`,
    "g",
  );
  return [...content.matchAll(pattern)].map(([match]) => [
    match.slice(0, match.lastIndexOf(":")),
    match.slice(match.lastIndexOf(":") + 1),
  ]);
}

/**
 * Moves image to version in content. A digest-pinned reference takes the new digest; a tag-only one,
 * such as a FROM line, keeps no digest.
 */
export function rewrite(content, image, version, digest) {
  const name = escape(image);
  return content
    .replace(
      new RegExp(String.raw`${name}:${semver}@sha256:[a-f0-9]{64}`, "g"),
      `${image}:${version}@${digest}`,
    )
    .replace(
      new RegExp(String.raw`${name}:${semver}(?=[^@0-9.]|$)`, "gm"),
      `${image}:${version}`,
    );
}

// A failure's message carries the command's stderr.
const run = (command, args, input) =>
  execFileSync(command, args, {
    encoding: "utf8",
    input,
    stdio: "pipe",
  }).trim();
const gh = (...args) => run("gh", args);

function headVersion(repository, branch) {
  try {
    return branchVersion(
      gh(
        "api",
        `repos/${repository}/commits/heads/${branch}`,
        "--jq",
        ".commit.message",
      ),
    );
  } catch {
    return "";
  }
}

function pin(env, source, released) {
  const {
    GH_REPO,
    APP,
    GITHUB_REPOSITORY_OWNER,
    GITHUB_SERVER_URL,
    GITHUB_STEP_SUMMARY,
  } = env;
  if (
    !new RegExp(`^${escape(GITHUB_REPOSITORY_OWNER)}/[a-z0-9-]+$`).test(source)
  ) {
    throw new Error(
      `Cannot pin "${source}": not a repository of ${GITHUB_REPOSITORY_OWNER}.`,
    );
  }
  const branch = `chore/deps/${source.split("/")[1]}`;
  // A late dispatch never moves a pull request back: it keeps the newest release seen, and master's
  // pins are the floor.
  const version =
    released && !isRelease(released)
      ? released
      : newest(released, headVersion(GH_REPO, branch));
  if (!isRelease(version))
    throw new Error(`Cannot pin ${source} at "${version}": not a release tag.`);

  run("git", ["reset", "-q", "--hard"]);
  const files = run("git", ["ls-files", "--", ...paths])
    .split("\n")
    .filter(Boolean);
  const found = files.flatMap((file) =>
    pins(readFileSync(file, "utf8"), source),
  );
  const current = newest(...found.map(([, pinned]) => pinned));
  if (!current) {
    console.log(`::notice::Infra pins no image of ${source}.`);
    return;
  }
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
  if (newest(version, current) === current) {
    console.log(`::notice::master already pins ${source} ${current}.`);
    if (pr)
      gh(
        "pr",
        "close",
        pr,
        "--delete-branch",
        "--comment",
        `master already pins ${source} ${current}.`,
      );
    return;
  }

  for (const image of [...new Set(found.map(([name]) => name))].sort()) {
    const manifest = execFileSync("skopeo", [
      "inspect",
      "--raw",
      `docker://${image}:${version}`,
    ]);
    const digest = `sha256:${createHash("sha256").update(manifest).digest("hex")}`;
    for (const file of files) {
      const content = readFileSync(file, "utf8");
      const moved = rewrite(content, image, version, digest);
      if (moved !== content) writeFileSync(file, moved);
    }
  }

  // master requires signed commits, and GitHub signs only those an App makes through its API.
  const title = `chore(deps): update ${source.split("/")[1]} images to ${version}`;
  const changed = run("git", ["diff", "--name-only"])
    .split("\n")
    .filter(Boolean);
  const tree = run(
    "gh",
    ["api", `repos/${GH_REPO}/git/trees`, "--input", "-", "--jq", ".sha"],
    JSON.stringify({
      base_tree: run("git", ["rev-parse", "HEAD^{tree}"]),
      tree: changed.map((path) => ({
        path,
        mode: "100644",
        type: "blob",
        content: readFileSync(path, "utf8"),
      })),
    }),
  );
  const parent = run("git", ["rev-parse", "HEAD"]);
  const commit = gh(
    "api",
    `repos/${GH_REPO}/git/commits`,
    "-f",
    `message=${title}`,
    "-f",
    `tree=${tree}`,
    "-f",
    `parents[]=${parent}`,
    "--jq",
    ".sha",
  );
  if (newest(version, headVersion(GH_REPO, branch)) !== version) {
    console.log(`::notice::A concurrent run pinned a newer ${source} release.`);
    return;
  }
  try {
    gh(
      "api",
      "-X",
      "PATCH",
      `repos/${GH_REPO}/git/refs/heads/${branch}`,
      "-f",
      `sha=${commit}`,
      "-F",
      "force=true",
      "--silent",
    );
  } catch {
    gh(
      "api",
      `repos/${GH_REPO}/git/refs`,
      "-f",
      `ref=refs/heads/${branch}`,
      "-f",
      `sha=${commit}`,
      "--silent",
    );
  }

  const body = `Deploys [${source} ${version}](${GITHUB_SERVER_URL}/${source}/releases/tag/${version}), whose release published every image pinned here.`;
  const url = pr
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
  console.log(`Pinned ${source} ${version}: ${url}`);
  appendFileSync(GITHUB_STEP_SUMMARY, `Pinned ${source} ${version}: ${url}\n`);
}

async function main(env) {
  if (env.EVENT === "repository_dispatch")
    return pin(env, env.RELEASE_REPOSITORY, env.RELEASE_VERSION);
  // GitHub computes mergeability lazily after a push, so UNKNOWN means "ask again".
  let prs = [];
  for (let attempt = 1; attempt <= 6; attempt++) {
    prs = JSON.parse(
      gh(
        "pr",
        "list",
        "--app",
        env.APP,
        "--json",
        "headRefName,title,mergeable",
      ),
    ).filter(
      (pr) =>
        pr.headRefName.startsWith("chore/deps/") &&
        /^chore\(deps\): update [a-z0-9-]+ images to v/.test(pr.title),
    );
    if (!prs.some((pr) => pr.mergeable === "UNKNOWN")) break;
    if (attempt < 6) await new Promise((resolve) => setTimeout(resolve, 15000));
  }
  for (const pr of prs.filter((pr) => pr.mergeable === "CONFLICTING")) {
    pin(
      env,
      `${env.GITHUB_REPOSITORY_OWNER}/${pr.headRefName.slice("chore/deps/".length)}`,
      "",
    );
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await main(process.env);
  } catch (error) {
    console.log(`::error::${error.message}`);
    process.exit(1);
  }
}

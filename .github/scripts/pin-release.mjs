// Pins every image of a service or platform release in one pull request per repository, opened as
// the Dependencies App, and rebuilds the release pull requests a merge left conflicting. The
// version rules and the rewrite are pure functions; main runs git, gh and skopeo around them.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { isRelease, newest, semver } from "./versions.mjs";

export const paths = [":(glob)environments/production/*/terraform.tfvars"];
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
    String.raw`(ghcr\.io/${escape(source)}(?:/[a-z0-9._/-]+)?):(${semver})`,
    "g",
  );
  return [...content.matchAll(pattern)].map((match) => match.slice(1));
}

/** Moves every digest-pinned reference to image in content to version and digest. */
export function rewrite(content, image, version, digest) {
  return content.replace(
    new RegExp(String.raw`${escape(image)}:${semver}@sha256:[a-f0-9]{64}`, "g"),
    `${image}:${version}@${digest}`,
  );
}

// A failure's message carries the command's stderr.
export const run = (command, args, input) =>
  execFileSync(command, args, {
    encoding: "utf8",
    input,
    stdio: "pipe",
  }).trim();
export const gh = (...args) => run("gh", args);
const lines = (text) => text.split("\n").filter(Boolean);

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

/** Whether master moved past the commit the working tree holds. */
const masterMoved = () =>
  run("git", ["ls-remote", "origin", "refs/heads/master"]).split("\t")[0] !==
  run("git", ["rev-parse", "HEAD"]);

/** Moves every image found to version, with the digest of its published manifest. */
function rewriteImages(files, images, version) {
  const digests = images.map((image) => {
    const manifest = execFileSync("skopeo", [
      "inspect",
      "--raw",
      `docker://${image}:${version}`,
    ]);
    return [
      image,
      `sha256:${createHash("sha256").update(manifest).digest("hex")}`,
    ];
  });
  for (const file of files) {
    const content = readFileSync(file, "utf8");
    const moved = digests.reduce(
      (text, [image, digest]) => rewrite(text, image, version, digest),
      content,
    );
    if (moved !== content) writeFileSync(file, moved);
  }
}

/**
 * Commits the working tree's changes on top of HEAD through the API, and returns the commit. master
 * requires signed commits, and GitHub signs only those an App makes through its API.
 */
export function commitChanges(repository, message) {
  const blob = (path) => ({
    path,
    mode: "100644",
    type: "blob",
    content: readFileSync(path, "utf8"),
  });
  const tree = run(
    "gh",
    ["api", `repos/${repository}/git/trees`, "--input", "-", "--jq", ".sha"],
    JSON.stringify({
      base_tree: run("git", ["rev-parse", "HEAD^{tree}"]),
      tree: lines(run("git", ["diff", "--name-only"])).map(blob),
    }),
  );
  const parent = run("git", ["rev-parse", "HEAD"]);
  return gh(
    "api",
    `repos/${repository}/git/commits`,
    "-f",
    `message=${message}`,
    "-f",
    `tree=${tree}`,
    "-f",
    `parents[]=${parent}`,
    "--jq",
    ".sha",
  );
}

/** Points branch at commit, creating the branch when it does not exist. */
export function moveBranch(repository, branch, commit) {
  try {
    gh(
      "api",
      "-X",
      "PATCH",
      `repos/${repository}/git/refs/heads/${branch}`,
      "-f",
      `sha=${commit}`,
      "-F",
      "force=true",
      "--silent",
    );
  } catch {
    gh(
      "api",
      `repos/${repository}/git/refs`,
      "-f",
      `ref=refs/heads/${branch}`,
      "-f",
      `sha=${commit}`,
      "--silent",
    );
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

  // Runs overlap, and the one that started first can finish last. Each pin therefore builds on
  // master's current tip.
  run("git", ["fetch", "-q", "--depth=1", "origin", "master"]);
  run("git", ["reset", "-q", "--hard", "FETCH_HEAD"]);
  const files = lines(run("git", ["ls-files", "--", ...paths]));
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

  rewriteImages(
    files,
    [...new Set(found.map(([name]) => name))].sort(),
    version,
  );
  const title = `chore(deps): update ${source.split("/")[1]} images to ${version}`;
  const commit = commitChanges(GH_REPO, title);
  if (newest(version, headVersion(GH_REPO, branch)) !== version) {
    console.log(`::notice::A concurrent run pinned a newer ${source} release.`);
    return;
  }
  // A merge since the fetch leaves this commit behind master, and that merge's own run may already
  // have rebuilt the pull request. The pin then starts again from the new tip.
  if (masterMoved()) return pin(env, source, released);
  moveBranch(GH_REPO, branch, commit);

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

/** Whether a pull request is a release pin this workflow opened. */
const isReleasePin = (pr) =>
  pr.headRefName.startsWith("chore/deps/") &&
  /^chore\(deps\): update [a-z0-9-]+ images to v/.test(pr.title);

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
    ).filter(isReleasePin);
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

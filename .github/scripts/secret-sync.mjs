// Copies each repository's governance secrets from Secret Manager into its governance environment,
// after the GitHub root applies in a deploy or the sweep (a-novel/.github#534). The decision and the
// App's token are pure functions; main runs gcloud and gh around them. A value travels only through
// a pipe from gcloud to gh, so it never reaches a log, a variable or an argument.
import { execFileSync, spawnSync } from "node:child_process";
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * What a governance environment needs. It writes each secret it should hold that GitHub lacks or
 * holds in a copy older than the pinned version, and deletes each one no workflow names.
 */
export function plan(wanted, live, created) {
  return {
    write: wanted.filter((name) => !live[name] || created[name] > live[name]),
    remove: Object.keys(live)
      .filter((name) => !wanted.includes(name))
      .sort(),
  };
}

const base64url = (value) => Buffer.from(value).toString("base64url");

/** A JSON Web Token that authenticates as the App for 10 minutes, backdated against clock drift. */
export function appJwt(appId, key, now = Date.now()) {
  const seconds = Math.floor(now / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({
      iat: seconds - 60,
      exp: seconds + 540,
      iss: String(appId),
    }),
  );
  return `${header}.${claims}.${createSign("RSA-SHA256").update(`${header}.${claims}`).sign(key, "base64url")}`;
}

async function github(token, method, path) {
  const response = await fetch(`https://api.github.com/${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!response.ok)
    throw new Error(`${method} ${path}: HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}

const gcloud = (project, ...args) =>
  execFileSync("gcloud", [...args, `--project=${project}`], {
    encoding: "utf8",
  }).trim();

/**
 * Pipes one secret version's payload from gcloud into gh, which encrypts it for the environment. The
 * pipe runs in bash, so the value never reaches this process; its arguments name it, never hold it.
 */
export function copy(project, source, repository, name, token) {
  const { status } = spawnSync(
    "bash",
    [
      "-o",
      "pipefail",
      "-c",
      'gcloud secrets versions access "$1" --secret="$2" --project="$3" | gh secret set "$4" --env governance --repo "$5" >/dev/null',
      "copy",
      String(source.version),
      source.secret,
      project,
      name,
      repository,
    ],
    {
      stdio: ["ignore", "inherit", "inherit"],
      env: { ...process.env, GH_TOKEN: token },
    },
  );
  if (status !== 0) throw new Error(`copy ${name} into ${repository} failed`);
}

export async function main(organizations) {
  for (const [owner, { project, app, secrets, repositories }] of Object.entries(
    organizations,
  )) {
    const key = gcloud(
      project,
      "secrets",
      "versions",
      "access",
      String(app.key.version),
      `--secret=${app.key.secret}`,
    );
    const { token } = await github(
      appJwt(app.id, key),
      "POST",
      `app/installations/${app.installation_id}/access_tokens`,
    );
    console.log(`::add-mask::${token}`);

    const created = Object.fromEntries(
      Object.entries(secrets).map(([name, source]) => [
        name,
        new Date(
          gcloud(
            project,
            "secrets",
            "versions",
            "describe",
            String(source.version),
            `--secret=${source.secret}`,
            "--format=value(createTime)",
          ),
        ),
      ]),
    );

    for (const [name, wanted] of Object.entries(repositories)) {
      const repository = `${owner}/${name}`;
      const { secrets: held } = await github(
        token,
        "GET",
        `repos/${repository}/environments/governance/secrets?per_page=100`,
      );
      const { write, remove } = plan(
        wanted,
        Object.fromEntries(
          held.map((secret) => [secret.name, new Date(secret.updated_at)]),
        ),
        created,
      );
      for (const secret of remove)
        await github(
          token,
          "DELETE",
          `repos/${repository}/environments/governance/secrets/${secret}`,
        );
      for (const secret of write)
        copy(project, secrets[secret], repository, secret, token);
      if (write.length + remove.length > 0) {
        console.log(
          `${repository}: wrote ${write.join(", ") || "nothing"}; deleted ${remove.join(", ") || "nothing"}.`,
        );
      }
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main(JSON.parse(readFileSync(process.argv[2], "utf8")));
}

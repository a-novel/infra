import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const guides = [
  "docs/setup-production.md",
  ...(await readdir(new URL("docs/runbooks/", root)))
    .filter((name) => name.endsWith(".md"))
    .map((name) => `docs/runbooks/${name}`),
];

// Scan one command, preserving newlines inside quoted Logging filters. This is
// deliberately not a shell evaluator: no documented command runs in this test.
function commandAt(body, start) {
  let quote = "";
  for (let index = start; index < body.length; index += 1) {
    const char = body[index];
    if (char === "\\" && quote !== "'") {
      index += 1;
      continue;
    }
    if (quote) {
      if (char === quote) quote = "";
    } else if (char === "'" || char === '"') quote = char;
    else if ("\n;|)".includes(char)) return body.slice(start, index);
  }
  return body.slice(start);
}

test("operator gcloud commands select explicit projects or exact resources", async () => {
  let checked = 0;
  for (const name of guides) {
    const content = await readFile(new URL(name, root), "utf8");
    for (const block of content.matchAll(
      /```(?:sh|zsh|bash)\n([\s\S]*?)\n```/g,
    )) {
      const body = block[1].replaceAll(/\\\n/g, " ");
      for (const match of body.matchAll(/\bgcloud\s+/g)) {
        const command = commandAt(body, match.index);
        checked += 1;
        if (
          /^gcloud (?:auth|config|version|organizations|billing)\b/.test(
            command,
          )
        )
          continue;
        if (
          /^gcloud projects \S+ "\$\{?(?:INFRA_MANAGEMENT_PROJECT_ID|INFRA_WORKLOAD_PROJECT_ID|MANAGEMENT_PROJECT_ID|WORKLOAD_PROJECT_ID|SOURCE_PROJECT_ID|REPLACEMENT_PROJECT_ID)\}?"/.test(
            command,
          )
        )
          continue;
        if (/^gcloud resource-manager folders\b/.test(command)) continue;
        if (/^gcloud storage\b/.test(command)) {
          assert.match(
            command,
            /gs:\/\/\$\{|"\$\{?STATE_OBJECT\}?(?:"|#)/,
            `${name}: ${command}`,
          );
          continue;
        }
        assert.match(
          command,
          /--project=(?:"\$\{?[A-Z_]+(?::\?[^}]+)?\}?"|cos-cloud\b)/,
          `${name}: ${command}`,
        );
      }
    }
  }
  assert.ok(checked > 100);
});

test("initializer handoff is current, explicitly scoped, and never overrides execution", async () => {
  const setup = await readFile(
    new URL("docs/setup-production.md", root),
    "utf8",
  );
  const prompt = await readFile(
    new URL("ops/await-auth-initialization.sh", root),
    "utf8",
  );
  assert.match(
    prompt,
    /docs\/setup-production\.md#run-the-human-only-authentication-initializer/,
  );
  assert.doesNotMatch(prompt, /deploy-production\.md#first-launch/);
  const commands = [
    ...setup.matchAll(
      /^gcloud run jobs execute agora-authentication-init (.+)$/gm,
    ),
  ];
  assert.equal(commands.length, 1);
  assert.match(commands[0][1], /--project="\$\{INFRA_WORKLOAD_PROJECT_ID:\?/);
  assert.match(commands[0][1], /--region="\$\{REGION:\?/);
  assert.match(commands[0][1], /--wait$/);
  assert.doesNotMatch(
    commands[0][1],
    /--(?:args|command|update-env-vars|set-env-vars|tasks|task-timeout)/,
  );
  assert.match(setup, /Do not rerun the initializer or remove its marker/);
  assert.match(setup, /secretAliases/);
});

test("initializer inspection never prints literal environment values", async () => {
  const setup = await readFile(
    new URL("docs/setup-production.md", root),
    "utf8",
  );
  const filter = setup.match(/\| jq '(\{secretAliases:[^\n]+)'/)[1];
  const payload = {
    spec: {
      template: {
        metadata: {
          annotations: {
            "run.googleapis.com/secrets":
              "alias:projects/123/secrets/auth-password",
          },
        },
        spec: {
          template: {
            spec: {
              containers: [
                {
                  env: [
                    {
                      name: "SUPER_ADMIN_PASSWORD",
                      value: "fixture-private-response",
                    },
                    {
                      name: "POSTGRES_PASSWORD",
                      valueFrom: { secretKeyRef: { name: "alias", key: "2" } },
                    },
                  ],
                },
              ],
            },
          },
        },
      },
    },
  };
  const result = spawnSync("jq", [filter], {
    input: JSON.stringify(payload),
    encoding: "utf8",
  });
  assert.equal(result.status, 0);
  assert.doesNotMatch(
    result.stdout + result.stderr,
    /fixture-private-response/,
  );
  const report = JSON.parse(result.stdout);
  assert.equal(report.inputs[0].hasValue, true);
  assert.deepEqual(report.inputs[1].secretRef, { name: "alias", key: "2" });
});

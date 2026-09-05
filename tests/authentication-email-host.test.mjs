import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { compileRelease } from "../ops/compile-release.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const fixture = JSON.parse(
  await readFile(path.join(root, "tests/fixtures/release-config.json"), "utf8"),
);

async function compile(t, origin) {
  const scratch = await mkdtemp(path.join(root, ".release-test-"));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const config = structuredClone(fixture);
  config.authentication.web_client_url = origin;
  const configPath = path.join(scratch, "config.json");
  await writeFile(configPath, JSON.stringify(config));
  return compileRelease({
    manifestPath: path.join(root, "tests/fixtures/manifests/valid.yaml"),
    configPath,
    outputDirectory: path.join(scratch, "out"),
    commit: "a".repeat(40),
    runId: "123",
    runAttempt: 1,
    nonce: "email-host",
  });
}

test("a configured hosting origin reaches candidate and active inputs", async (t) => {
  const origin = "https://studio.another-domain.example";
  const result = await compile(t, origin);
  assert.equal(
    result.candidateTfvars.application_release.authentication.web_client_url,
    origin,
  );
  assert.equal(
    result.activeTfvars.application_release.authentication.web_client_url,
    origin,
  );
  assert.equal(result.rollbackTfvars.application_release, null);
});

for (const [label, origin] of Object.entries({
  missing: undefined,
  null: null,
  empty: "",
  relative: "/account",
  insecure: "http://www.example.com",
  credentials: "https://fixture-private-value@www.example.com",
  path: "https://www.example.com/account",
  slash: "https://www.example.com/",
  query: "https://www.example.com?token=fixture-private-value",
  fragment: "https://www.example.com#fixture-private-value",
  whitespace: " https://www.example.com",
  invalidPort: "https://www.example.com:99999",
  backslash: "https://www.example.com\\account",
})) {
  test(`release compilation rejects ${label} email origin without printing it`, async (t) => {
    await assert.rejects(compile(t, origin), {
      message:
        "authentication.web_client_url must be an HTTPS origin without credentials, path, query, fragment, or trailing slash",
    });
  });
}

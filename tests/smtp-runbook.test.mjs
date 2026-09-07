import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const guide = await readFile(
  new URL("docs/runbooks/configure-hosted-smtp.md", root),
  "utf8",
);
const blocks = [...guide.matchAll(/```(?:sh|zsh)\n([\s\S]*?)\n```/g)].map(
  (match) => match[1],
);
const sendBlock = blocks.find((body) =>
  body.includes("/v2/short-code/register"),
);
const healthBlock = blocks.find((body) => body.includes("/v2/healthcheck"));

// Intercept both network clients: these tests execute the documented blocks, but never
// contact Google Cloud, retrieve a credential, or send mail.
const mocks = String.raw`
gcloud() {
[[ "$*" == "run services describe agora-authentication-rest --project="*" --region="*" --format=value(status.url)" ]] || return 90
[[ "$SCENARIO" != denied ]] || return 1
printf '%s' 'https://fixture-auth.run.app'
}
curl() {
[[ "$1" == -q ]] || return 90
[[ "$*" != *fixture-private-token* && "$*" != *--retry* && "$*" != *--location* ]] || return 91
case "$argv[-1]" in
*/v2/healthcheck)
printf 'CALL health\n' >&2
[[ "$SCENARIO" != unhealthy ]] || { printf '{"client:smtp":{"status":"down","error":"fixture-private-response"}}'; return 22; }
printf '{"client:smtp":{"status":"up"},"client:postgres":{"status":"up"},"api:jsonKeys":{"status":"up"}}'
;;
*/v2/session/anon)
printf 'CALL anon\n' >&2
[[ "$*" == *"--request PUT"* ]] || return 92
case "$SCENARIO" in
anon-failed) return 22 ;;
invalid-json) printf 'not-json'; return ;;
missing-token) printf '{}'; return ;;
newline-token) printf '%s' '{"accessToken":"bad\nheader"}'; return ;;
esac
printf '%s' '{"accessToken":"fixture-private-token","refreshToken":"fixture-private-refresh"}'
;;
*/v2/short-code/register)
printf 'CALL register\n' >&2
[[ "$*" == *"--request PUT"* && "$*" == *"--header @-"* && "$*" == *"--output /dev/null"* ]] || return 93
[[ "$*" == *'{"email":"controlled@example.net","lang":"en"}'* ]] || return 94
local header
IFS= read -r header
[[ "$header" == 'Authorization: Bearer fixture-private-token' ]] || return 95
[[ "$SCENARIO" != mail-timeout ]] || return 28
if [[ "$SCENARIO" == wrong-status ]]; then printf '200'; else printf '202'; fi
;;
*) return 96 ;;
esac
}
`;

function run(body, scenario = "success", overrides = {}) {
  const result = spawnSync("zsh", ["-f", "-c", mocks + "\n" + body], {
    cwd: root,
    env: {
      ...process.env,
      SCENARIO: scenario,
      AUTH_URL: "https://fixture-auth.run.app",
      SMTP_TEST_EMAIL: "controlled@example.net",
      ...overrides,
    },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.ifError(result.error);
  const output = result.stdout + result.stderr;
  assert.doesNotMatch(output, /fixture-private-(?:token|refresh|response)/);
  return output;
}

test("SMTP guide shell blocks parse in zsh", () => {
  assert.ok(sendBlock && healthBlock);
  for (const body of blocks) {
    const result = spawnSync("zsh", ["-fn"], { input: body, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  }
});

test("SMTP delivery uses anonymous auth and exactly one correctly formed request", () => {
  const output = run(sendBlock);
  assert.doesNotMatch(output, /STOP/);
  assert.match(output, /Request accepted/);
  assert.equal((output.match(/CALL anon/g) ?? []).length, 1);
  assert.equal((output.match(/CALL register/g) ?? []).length, 1);
  assert.doesNotMatch(
    sendBlock,
    /--insecure|--verbose|--trace|mktemp|secrets versions access/,
  );
});

for (const scenario of [
  "anon-failed",
  "invalid-json",
  "missing-token",
  "newline-token",
]) {
  test(`SMTP delivery stops before sending with ${scenario}`, () => {
    const output = run(sendBlock, scenario);
    assert.match(output, /STOP/);
    assert.doesNotMatch(output, /CALL register|Request accepted/);
  });
}

for (const scenario of ["mail-timeout", "wrong-status"]) {
  test(`SMTP delivery does not retry or report success with ${scenario}`, () => {
    const output = run(sendBlock, scenario);
    assert.match(output, /STOP/);
    assert.doesNotMatch(output, /Request accepted/);
    assert.equal((output.match(/CALL register/g) ?? []).length, 1);
  });
}

for (const overrides of [
  { SMTP_TEST_EMAIL: "" },
  { SMTP_TEST_EMAIL: "not-an-email" },
  { AUTH_URL: "http://untrusted.example" },
]) {
  test(`SMTP delivery rejects missing or invalid inputs ${JSON.stringify(overrides)}`, () => {
    const output = run(sendBlock, "success", overrides);
    assert.match(output, /STOP|Set a controlled/);
    assert.doesNotMatch(output, /CALL|Request accepted/);
  });
}

test("SMTP health discovers the scoped service and checks dependency states", () => {
  const output = run(healthBlock);
  assert.doesNotMatch(output, /STOP/);
  assert.match(output, /true/);
  assert.match(output, /CALL health/);
});

test("SMTP health never succeeds after a permission or upstream health failure", () => {
  for (const scenario of ["denied", "unhealthy"]) {
    const output = run(healthBlock, scenario);
    assert.match(output, /STOP/);
    assert.doesNotMatch(output, /true/);
    if (scenario === "denied") assert.doesNotMatch(output, /CALL health/);
  }
});

test("SMTP read grants expire and cleanup preserves existing unconditional roles", () => {
  assert.match(guide, /request\.time < timestamp/);
  assert.match(guide, /date -u -d '\+1 hour'/);
  for (const body of blocks.filter((value) =>
    value.includes("iam-policy-binding"),
  )) {
    assert.match(body, /--condition="\$\{?SMTP_AUDIT_CONDITION/);
    assert.doesNotMatch(
      body,
      /--condition=None|roles\/(?:owner|editor|run\.admin)/,
    );
  }
});

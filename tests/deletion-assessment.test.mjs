import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtemp,
  mkdir,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));
const base = "b".repeat(40);
const privateValue = "fixture-private-configuration";

async function assess(t, config, overrides = {}) {
  const directory = await mkdtemp(join(tmpdir(), "deletion-assessment-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const candidate = join(directory, "candidate");
  const bin = join(directory, "bin");
  const storage = join(directory, "storage");
  await mkdir(candidate);
  await mkdir(bin);
  await mkdir(storage);

  const git = (...args) => {
    const result = spawnSync("git", ["-C", candidate, ...args], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git("init", "-q", "-b", "master");
  git(
    "-c",
    "user.name=fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    "fixture",
  );
  const head = git("rev-parse", "HEAD");

  for (const [command, fixture] of Object.entries({
    gh: "fake-deletion-gate-gh.sh",
    gcloud: "fake-gcloud-storage.sh",
    tofu: "fake-tofu.sh",
  })) {
    await symlink(join(root, "tests/fixtures", fixture), join(bin, command));
  }
  for (const name of ["bootstrap", "foundation", "release"]) {
    if (name === "release" && config === undefined) continue;
    const path = join(storage, "agora-state-test", name, "config");
    await mkdir(path, { recursive: true });
    await writeFile(
      join(path, "00000000000000000001-00013.tfvars.json"),
      JSON.stringify(name === "release" ? { ...config, privateValue } : {}),
    );
  }

  const output = join(directory, "assessment.json");
  const result = spawnSync(
    join(root, "ops/prepare-resource-deletion-assessment.sh"),
    ["a-novel/infra", "93", head, base, candidate, "agora-state-test", output],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        FAKE_GATE_BASE: base,
        FAKE_GATE_HEAD: head,
        FAKE_GATE_FILES: "image",
        FAKE_GCS_ROOT: storage,
        FAKE_TOFU_PLAN_CODE: "0",
        FAKE_TOFU_PLAN_JSON: join(root, "tests/fixtures/plans/no-changes.json"),
        ...overrides,
      },
    },
  );
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(privateValue));
  if (result.status !== 0) {
    await assert.rejects(readFile(output), { code: "ENOENT" });
    return { result };
  }
  const verdict = JSON.parse(await readFile(output, "utf8"));
  assert.equal(verdict.headSha, head);
  assert.equal(verdict.baseSha, base);
  assert.deepEqual(Object.keys(verdict).sort(), [
    "approvalRequired",
    "baseSha",
    "firstLaunch",
    "headSha",
    "pullRequest",
    "repository",
    "schemaVersion",
  ]);
  return { result, verdict };
}

for (const [name, config, expected] of [
  ["no saved release configuration", undefined, true],
  [
    "empty first-launch rollback",
    { application_release: null, database_releases: {} },
    true,
  ],
  ["omitted optional application release", { database_releases: {} }, true],
  [
    "established application",
    { application_release: { rollout: { phase: "active" } } },
    false,
  ],
]) {
  test(`image assessment recognizes ${name}`, async (t) => {
    const { result, verdict } = await assess(t, config);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(verdict.firstLaunch, expected);
    assert.equal(verdict.approvalRequired, expected);
    if (expected) assert.doesNotMatch(result.stdout, /established release/);
  });
}

test("a clean infrastructure plan retains empty-rollback approval", async (t) => {
  const { result, verdict } = await assess(
    t,
    { application_release: null },
    {
      FAKE_GATE_FILES: "release",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(verdict.firstLaunch, true);
  assert.equal(verdict.approvalRequired, true);
  assert.match(result.stdout, /release candidate assessment completed/);
});

test("empty-rollback approval does not mask a failed infrastructure plan", async (t) => {
  const { result } = await assess(
    t,
    { application_release: null },
    {
      FAKE_GATE_FILES: "release",
      FAKE_TOFU_FAIL_ACTION: "plan",
    },
  );
  assert.notEqual(result.status, 0);
});

for (const failure of ["FAKE_GCS_LIST_FAILURE", "FAKE_GCS_READ_FAILURE"]) {
  test(`assessment fails closed on ${failure}`, async (t) => {
    const { result } = await assess(
      t,
      { application_release: null },
      {
        [failure]: "true",
      },
    );
    assert.equal(result.status, 70);
  });
}

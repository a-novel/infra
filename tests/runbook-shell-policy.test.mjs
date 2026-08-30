import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const runbookDirectory = path.join(repositoryRoot, "docs/runbooks");
const stopHandler =
  "} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'";

const runbookNames = (await readdir(runbookDirectory))
  .filter((name) => name.endsWith(".md"))
  .sort();
const runbooks = await Promise.all(
  runbookNames.map(async (name) => ({
    name,
    content: await readFile(path.join(runbookDirectory, name), "utf8"),
  })),
);

test("local runbook commands are scoped for the configured zsh session", () => {
  let zshBlockCount = 0;

  for (const { name, content } of runbooks) {
    assert.doesNotMatch(content, /set -euo pipefail|set \+x/);
    for (const match of content.matchAll(/```zsh\n([\s\S]*?)\n```/g)) {
      zshBlockCount += 1;
      assert.ok(
        match[1].startsWith(
          "() {\nsetopt local_options err_return pipe_fail\nunsetopt err_exit nounset xtrace\n",
        ),
        `${name} contains an unscoped zsh block`,
      );
      assert.ok(
        match[1].endsWith(stopHandler),
        `${name} contains a zsh block without the terminal-safe stop handler`,
      );
    }
  }

  assert.ok(zshBlockCount > 0);
});

test("workflow commands keep restartable repository-state boundaries", () => {
  let workflowInvocationBlockCount = 0;

  for (const { name, content } of runbooks) {
    assert.doesNotMatch(
      content,
      /MASTER_SHA|EXPECTED_SHA/,
      `${name} carries workflow commit state between commands`,
    );
    for (const match of content.matchAll(/```zsh\n([\s\S]*?)\n```/g)) {
      const body = match[1];

      if (body.includes("git pull --ff-only")) {
        assert.doesNotMatch(
          body,
          /MASTER_SHA=|\.\/ops\/run-workflow\.sh/,
          `${name} combines repository refresh with commit collection or workflow invocation`,
        );
      }

      if (body.includes("./ops/run-workflow.sh")) {
        workflowInvocationBlockCount += 1;
        assert.doesNotMatch(
          body,
          /git switch master|git pull --ff-only|MASTER_SHA=.*git rev-parse/,
          `${name} combines workflow invocation with repository-state collection`,
        );
      }
    }
  }

  assert.ok(workflowInvocationBlockCount > 0);
});

test("migrated first-run guides use stateless operator commands", () => {
  for (const name of ["README.md", "provision-workload-foundation.md"]) {
    const { content } = runbooks.find((runbook) => runbook.name === name);

    assert.doesNotMatch(
      content,
      /\(\) \{|setopt |unsetopt |MASTER_SHA|EXPECTED_SHA/,
    );
  }

  const allRunbooks = runbooks.map(({ content }) => content).join("\n");
  assert.doesNotMatch(
    allRunbooks,
    /run-workflow\.sh\s+(drift|foundation|release|recovery)\.yaml/,
  );
  assert.doesNotMatch(allRunbooks, /run-workflow\.sh[\s\\\n]+.*operation=/);
  assert.match(allRunbooks, /run-workflow\.sh foundation plan foundation/);
  assert.match(allRunbooks, /foundation\.sh configure/);
  assert.match(allRunbooks, /foundation-audit\.sh/);
});

test("runbook operator-script links resolve to executable files", async () => {
  const linkedScripts = new Set();

  for (const { content } of runbooks) {
    for (const match of content.matchAll(
      /(?:\.\.\/\.\.\/|\.\/)ops\/([a-z0-9-]+\.sh)/g,
    )) {
      linkedScripts.add(match[1]);
    }
  }

  assert.ok(linkedScripts.size > 0);
  for (const script of linkedScripts) {
    const metadata = await stat(path.join(repositoryRoot, "ops", script));
    assert.ok(metadata.isFile(), `${script} is not a file`);
    assert.notEqual(metadata.mode & 0o111, 0, `${script} is not executable`);
  }
});

test("Bash fences are limited to commands pasted inside remote COS hosts", () => {
  const bashBlocks = [];
  for (const { name, content } of runbooks) {
    for (const match of content.matchAll(/```bash\n([\s\S]*?)\n```/g)) {
      bashBlocks.push({ name, body: match[1] });
    }
  }

  assert.equal(bashBlocks.length, 5);
  assert.equal(
    bashBlocks.filter(({ name }) => name === "operate-postgresql-host.md")
      .length,
    4,
  );
  assert.equal(
    bashBlocks.filter(({ name }) => name === "disaster-recovery.md").length,
    1,
  );
  assert.ok(
    bashBlocks.every(
      ({ name, body }) =>
        (name === "operate-postgresql-host.md" &&
          (body.startsWith("sudo docker") ||
            body.startsWith("for container in agora-postgres-json-keys"))) ||
        (name === "disaster-recovery.md" &&
          body.startsWith("RECOVERY_AUTH_URL=''")),
    ),
  );
});

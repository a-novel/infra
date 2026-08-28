import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
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

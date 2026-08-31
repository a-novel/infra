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
const directSessionAssignment = /^export SMTP_DKIM_CNAME_RECORDS='[^'\n]+'$/;

const runbookNames = (await readdir(runbookDirectory))
  .filter((name) => name.endsWith(".md"))
  .sort();
const runbooks = await Promise.all(
  runbookNames.map(async (name) => ({
    name,
    content: await readFile(path.join(runbookDirectory, name), "utf8"),
  })),
);
const setupGuide = {
  name: "setup-production.md",
  content: await readFile(
    path.join(repositoryRoot, "docs/setup-production.md"),
    "utf8",
  ),
};
const operatorGuides = [setupGuide, ...runbooks];

async function collectFiles(directory) {
  const files = [];

  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);

    if (entry.isDirectory()) {
      files.push(...(await collectFiles(entryPath)));
    } else if (entry.isFile()) {
      files.push(entryPath);
    }
  }

  return files;
}

test("local runbook commands are scoped for the configured zsh session", () => {
  let zshBlockCount = 0;

  for (const { name, content } of operatorGuides) {
    assert.doesNotMatch(content, /set -euo pipefail|set \+x/);
    for (const match of content.matchAll(/```zsh\n([\s\S]*?)\n```/g)) {
      zshBlockCount += 1;
      if (directSessionAssignment.test(match[1])) {
        continue;
      }

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

test("hosted SMTP operator inputs are parameterized", () => {
  const { content: smtpRunbook } = runbooks.find(
    (runbook) => runbook.name === "configure-hosted-smtp.md",
  );
  const { content: deploymentRunbook } = runbooks.find(
    (runbook) => runbook.name === "deploy-production.md",
  );

  for (const content of [smtpRunbook, deploymentRunbook]) {
    assert.doesNotMatch(content, /^\s*SMTP_[A-Z0-9_]*=/m);
  }

  for (const variable of [
    "SMTP_HOST",
    "SMTP_USERNAME",
    "SMTP_SENDER_EMAIL",
    "SMTP_SENDER_NAME",
    "SMTP_DKIM_CNAME_RECORDS",
  ]) {
    assert.match(smtpRunbook, new RegExp(`\\b${variable}\\b`));
  }

  assert.match(smtpRunbook, /^export SMTP_DKIM_CNAME_RECORDS='[^']+'$/m);
  assert.doesNotMatch(
    smtpRunbook,
    /IFS=\s*read\s+-r\s+SMTP_DKIM_CNAME_RECORDS/,
  );

  assert.doesNotMatch(
    smtpRunbook,
    /^\s*(?:SENDING_DOMAIN|DMARC_REPORT_EMAIL|DKIM_SELECTORS)=/m,
  );
  assert.match(smtpRunbook, /sender_domain="\$\{SMTP_SENDER_EMAIL##\*@\}"/);
  assert.match(
    smtpRunbook,
    /dmarc_report_email="dmarc-reports@\$\{sender_domain\}"/,
  );
});

test("workflow commands keep restartable repository-state boundaries", () => {
  let workflowInvocationBlockCount = 0;

  for (const { name, content } of operatorGuides) {
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

test("delegated setup procedures use stateless operator commands", () => {
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

test("database host operations are one-line restartable commands", () => {
  const { content: hostRunbook } = runbooks.find(
    (runbook) => runbook.name === "operate-postgresql-host.md",
  );
  const { content: debugRunbook } = runbooks.find(
    (runbook) => runbook.name === "debug-postgresql-host.md",
  );

  for (const content of [hostRunbook, debugRunbook]) {
    assert.doesNotMatch(content, /\(\) \{|setopt |unsetopt /);
  }
  for (const operation of ["inspect", "key", "ssh", "troubleshoot"]) {
    assert.match(
      debugRunbook,
      new RegExp(`^\\./ops/database-host\\.sh ${operation}(?: |$)`, "m"),
    );
  }
  assert.doesNotMatch(debugRunbook, /^gcloud compute ssh /m);
});

test("operator-owned project coordinates stay explicit and repeatable", async () => {
  const envrc = await readFile(path.join(repositoryRoot, ".envrc"), "utf8");
  const gitignore = await readFile(
    path.join(repositoryRoot, ".gitignore"),
    "utf8",
  );
  const exportLines = envrc
    .split("\n")
    .filter((line) => line.startsWith("export "));
  const exportNames = exportLines.map(
    (line) => line.match(/^export ([A-Z0-9_]+)='[^'\n]+'$/)?.[1],
  );

  assert.deepEqual(exportNames, [
    "INFRA_MANAGEMENT_PROJECT_ID",
    "INFRA_WORKLOAD_PROJECT_ID",
    "INFRA_REGION",
    "INFRA_DATABASE_ZONE",
    "INFRA_COST_ALERT_EMAIL",
    "INFRA_OPERATIONS_ALERT_EMAIL",
    "INFRA_DATABASE_OPERATOR_PRINCIPALS",
    "INFRA_AUTH_INITIALIZER_PRINCIPALS",
    "SMTP_HOST",
    "SMTP_USERNAME",
    "SMTP_SENDER_EMAIL",
    "SMTP_SENDER_NAME",
  ]);
  assert.doesNotMatch(
    exportLines.join("\n"),
    /SECRET|TOKEN|PASSWORD|CREDENTIAL|replace-with/,
  );
  assert.doesNotMatch(envrc, /\$\(|`|source |\. \.\//);
  assert.ok(
    !gitignore.split("\n").includes(".envrc"),
    ".envrc must remain tracked",
  );
  await assert.rejects(
    readFile(path.join(repositoryRoot, ".envrc.example"), "utf8"),
    (error) => error.code === "ENOENT",
  );

  const coordinateRunbooks = new Map([
    ["README.md", "./ops/verify-operator-env.sh --github"],
    ["backup-and-restore-postgresql.md", "--github"],
    ["bootstrap-management-plane.md", "./ops/verify-operator-env.sh\n"],
    ["debug-postgresql-host.md", "--github"],
    ["deploy-production.md", "--github"],
    ["disaster-recovery.md", "--github"],
    ["operate-postgresql-host.md", "--github"],
    ["provision-workload-foundation.md", "./ops/verify-operator-env.sh\n"],
    ["respond-to-alerts.md", "--github"],
    ["secret-versions.md", "--github"],
    ["state-recovery.md", "--github"],
  ]);

  for (const [name, verifier] of coordinateRunbooks) {
    const { content } = runbooks.find((runbook) => runbook.name === name);

    assert.match(content, /\. \.\/\.envrc/);
    assert.ok(
      content.includes(verifier),
      `${name} has the wrong verifier mode`,
    );
  }

  assert.ok(setupGuide.content.includes(". ./.envrc"));
  assert.ok(
    setupGuide.content.includes("./ops/verify-operator-env.sh --github"),
  );

  const operatorSources = [
    path.join(repositoryRoot, "README.md"),
    ...(await collectFiles(path.join(repositoryRoot, "docs"))),
    ...(await collectFiles(path.join(repositoryRoot, "ops"))),
    ...(await collectFiles(path.join(repositoryRoot, "tests"))),
  ];
  const retiredProjectIds = [
    ["agora", "production", "prod"].join("-"),
    ["a", "novel", "management", "prod"].join("-"),
    ["agora", "management", "prod"].join("-"),
  ];

  for (const sourcePath of operatorSources) {
    const content = await readFile(sourcePath, "utf8");

    for (const retiredProjectId of retiredProjectIds) {
      assert.ok(
        !content.includes(retiredProjectId),
        `${path.relative(repositoryRoot, sourcePath)} embeds a retired project ID`,
      );
    }
  }

  const foundationSources = [
    await readFile(path.join(repositoryRoot, "ops/foundation.sh"), "utf8"),
    await readFile(
      path.join(repositoryRoot, "ops/foundation-audit.sh"),
      "utf8",
    ),
    runbooks.find(
      (runbook) => runbook.name === "provision-workload-foundation.md",
    ).content,
  ].join("\n");
  assert.doesNotMatch(foundationSources, /--workload-project-id/);
  assert.match(foundationSources, /INFRA_MANAGEMENT_PROJECT_ID/);
  assert.match(foundationSources, /INFRA_WORKLOAD_PROJECT_ID/);
});

test("operator-guide script links resolve to executable files", async () => {
  const linkedScripts = new Set();

  for (const { content } of operatorGuides) {
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
  for (const { name, content } of operatorGuides) {
    for (const match of content.matchAll(/```bash\n([\s\S]*?)\n```/g)) {
      bashBlocks.push({ name, body: match[1] });
    }
  }

  assert.equal(bashBlocks.length, 5);
  assert.equal(
    bashBlocks.filter(({ name }) => name === "operate-postgresql-host.md")
      .length,
    1,
  );
  assert.equal(
    bashBlocks.filter(({ name }) => name === "debug-postgresql-host.md").length,
    3,
  );
  assert.equal(
    bashBlocks.filter(({ name }) => name === "disaster-recovery.md").length,
    1,
  );
  assert.ok(
    bashBlocks.every(
      ({ name, body }) =>
        ((name === "operate-postgresql-host.md" ||
          name === "debug-postgresql-host.md") &&
          (body.startsWith("sudo docker") ||
            body.startsWith("for container in agora-postgres-json-keys"))) ||
        (name === "disaster-recovery.md" &&
          body.startsWith("RECOVERY_AUTH_URL=''")),
    ),
  );
});

test("one-time production work lives only in the setup guide", () => {
  assert.match(
    setupGuide.content,
    /## 5\. Create the initial payload versions/,
  );
  assert.match(
    setupGuide.content,
    /\.\/ops\/add-secret-version\.sh[\s\\\n]+production-authentication-postgres-password/,
  );
  assert.match(
    setupGuide.content,
    /### Run the human-only Authentication initializer/,
  );
  assert.match(setupGuide.content, /## 7\. Lock backup retention/);

  const operationalNames = [
    "README.md",
    "backup-and-restore-postgresql.md",
    "configure-hosted-smtp.md",
    "deploy-production.md",
    "disaster-recovery.md",
    "operate-postgresql-host.md",
    "respond-to-alerts.md",
    "secret-versions.md",
  ];
  const setupOnlyHeadings =
    /First production run|Initial population|First-run handoff|First production activation|First launch:|Prepare the first database release|Lock retention after proof|Initializer partial-failure recovery/i;
  const operationalContent = operationalNames
    .map((name) => runbooks.find((runbook) => runbook.name === name).content)
    .join("\n");

  for (const name of operationalNames) {
    const { content } = runbooks.find((runbook) => runbook.name === name);

    assert.doesNotMatch(
      content,
      setupOnlyHeadings,
      `${name} contains setup work`,
    );
  }

  assert.doesNotMatch(
    operationalContent,
    /\.\/ops\/add-secret-version\.sh\s*\\\s*production-authentication-postgres-password\s*\\/,
  );
  assert.doesNotMatch(
    operationalContent,
    /gcloud run jobs deploy agora-authentication-init/,
  );
  assert.doesNotMatch(
    operationalContent,
    /gh variable set PRODUCTION_RELEASES_ENABLED[^\n]*--body true/,
  );
  assert.doesNotMatch(
    operationalContent,
    /retention_policy\.is_locked[^\n]*false[^\n]*true/,
  );
});

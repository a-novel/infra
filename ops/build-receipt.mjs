#!/usr/bin/env node

import { chmod, readFile, writeFile } from "node:fs/promises";

if (process.argv.length !== 7) {
  process.stderr.write(
    "usage: build-receipt.mjs <deployment|rollback> <release> <active-tfvars> <operations> <output>\n",
  );
  process.exit(64);
}

const [, , kind, releasePath, tfvarsPath, operationsPath, outputPath] =
  process.argv;

try {
  if (!new Set(["deployment", "rollback"]).has(kind)) {
    throw new Error("invalid receipt kind");
  }
  const [release, activeTfvars, operations] = await Promise.all(
    [releasePath, tfvarsPath, operationsPath].map(async (file) =>
      JSON.parse(await readFile(file, "utf8")),
    ),
  );
  const receipt = {
    schemaVersion: 1,
    kind,
    createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    sequence: {
      runId: release.runId,
      runAttempt: release.runAttempt,
    },
    source: {
      commit: release.commit,
      manifestSha256: release.manifestSha256,
    },
    activeTfvars,
    database: release.database,
    operations,
  };
  await writeFile(outputPath, `${JSON.stringify(receipt, null, 2)}\n`, {
    mode: 0o600,
  });
  await chmod(outputPath, 0o600);
} catch {
  process.stderr.write("Could not build the private release receipt.\n");
  process.exit(65);
}

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Shell integration tests use the real checkout binary, never a compiler mock.
const directory = mkdtempSync(path.join(os.tmpdir(), "infra-test-binary-"));
process.on("exit", () => rmSync(directory, { recursive: true, force: true }));
export const infra = path.join(directory, "infra");
execFileSync("go", ["build", "-mod=readonly", "-o", infra, "./cmd/infra"], {
  cwd: fileURLToPath(new URL("../../", import.meta.url)),
});
process.env.PATH = `${directory}${path.delimiter}${process.env.PATH}`;

export async function compileRelease(options) {
  execFileSync(
    infra,
    [
      "compile-release",
      options.manifestPath,
      options.configPath,
      options.previousReceiptPath || "-",
      options.outputDirectory,
    ],
    {
      env: {
        ...process.env,
        GITHUB_SHA: options.commit,
        GITHUB_RUN_ID: options.runId,
        GITHUB_RUN_ATTEMPT: String(options.runAttempt),
        RELEASE_ACTION: options.action || "deploy",
        PRIOR_IMAGE_MANIFEST: options.previousManifestPath || "",
        CURRENT_RECEIPT: options.currentReceiptPath || "",
      },
    },
  );
  const result = {};
  for (const [key, file] of Object.entries({
    release: "release.json",
    candidateTfvars: "candidate.tfvars.json",
    activeTfvars: "active.tfvars.json",
    rollbackTfvars: "rollback.tfvars.json",
  }))
    result[key] = JSON.parse(
      await readFile(path.join(options.outputDirectory, file), "utf8"),
    );
  return result;
}

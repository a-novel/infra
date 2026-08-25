#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");

if (process.argv.length !== 3) {
  process.stderr.write("usage: validate-receipt.mjs <receipt>\n");
  process.exit(64);
}

try {
  const schema = JSON.parse(
    await readFile(
      path.join(repositoryRoot, "deploy/production/receipt.schema.json"),
      "utf8",
    ),
  );
  const receipt = JSON.parse(await readFile(process.argv[2], "utf8"));
  const validate = new Ajv2020({ allErrors: true, strict: true }).compile(
    schema,
  );
  if (!validate(receipt)) throw new Error("schema mismatch");
} catch {
  process.stderr.write("Release receipt is invalid.\n");
  process.exit(65);
}

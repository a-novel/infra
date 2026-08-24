import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import { parse } from "yaml";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const schemaPath = path.join(repositoryRoot, "deploy/production/images.schema.json");

const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);

async function readManifest(relativePath) {
  return parse(await readFile(path.join(repositoryRoot, relativePath), "utf8"));
}

test("the production manifest matches its schema", async () => {
  const manifest = await readManifest("deploy/production/images.yaml");

  assert.equal(validate(manifest), true, JSON.stringify(validate.errors));
});

test("a stable SemVer image with a digest is accepted", async () => {
  const manifest = await readManifest("tests/fixtures/manifests/valid.yaml");

  assert.equal(validate(manifest), true, JSON.stringify(validate.errors));
});

test("a branch image tag is rejected", async () => {
  const manifest = await readManifest("tests/fixtures/manifests/branch-tag.yaml");

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.instancePath.endsWith("/tag")));
});

test("an image without a digest is rejected", async () => {
  const manifest = await readManifest("tests/fixtures/manifests/missing-digest.yaml");

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "required"));
});

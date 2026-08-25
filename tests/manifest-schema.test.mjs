import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import { parse } from "yaml";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const schemaPath = path.join(
  repositoryRoot,
  "deploy/production/images.schema.json",
);

const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);

async function readManifest(relativePath) {
  return parse(await readFile(path.join(repositoryRoot, relativePath), "utf8"));
}

const stableManifest = await readManifest(
  "tests/fixtures/manifests/valid.yaml",
);

function copyStableManifest() {
  return structuredClone(stableManifest);
}

test("the production manifest matches its schema", async () => {
  const manifest = await readManifest("deploy/production/images.yaml");

  assert.equal(validate(manifest), true, JSON.stringify(validate.errors));
});

test("a stable SemVer image with a digest is accepted", async () => {
  assert.equal(
    validate(copyStableManifest()),
    true,
    JSON.stringify(validate.errors),
  );
});

test("a branch image tag is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].images.grpc.tag = "feat-rotate-keys";

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.instancePath.endsWith("/tag")),
  );
});

test("an image without a digest is rejected", () => {
  const manifest = copyStableManifest();
  delete manifest.components["service-authentication"].images.rest.digest;

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "required"));
});

test("an enabled component must include its complete image family", () => {
  const manifest = copyStableManifest();
  delete manifest.components["service-json-keys"].images["jobs/rotatekeys"];

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "required"));
});

test("a standalone image is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-authentication"].images.standalone =
    structuredClone(manifest.components["service-authentication"].images.rest);

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "additionalProperties"),
  );
});

test("an unplanned future image is rejected", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].images["jobs/future"] =
    structuredClone(
      manifest.components["service-json-keys"].images["jobs/migrations"],
    );

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "additionalProperties"),
  );
});

test("an image repository must match its exact runtime slot", () => {
  const manifest = copyStableManifest();
  manifest.components["service-authentication"].images.rest.repository =
    "ghcr.io/a-novel/service-authentication/database";

  assert.equal(validate(manifest), false);
  assert.ok(validate.errors?.some((error) => error.keyword === "const"));
});

test("a disabled component cannot retain deployable images", () => {
  const manifest = copyStableManifest();
  manifest.components["service-json-keys"].enabled = false;

  assert.equal(validate(manifest), false);
  assert.ok(
    validate.errors?.some((error) => error.keyword === "maxProperties"),
  );
});

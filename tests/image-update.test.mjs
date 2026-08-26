import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

import { validateImageUpdate } from "../ops/validate-image-update.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const stableManifest = parse(
  await readFile(
    path.join(repositoryRoot, "tests/fixtures/manifests/valid.yaml"),
    "utf8",
  ),
);

function copyStableManifest() {
  return structuredClone(stableManifest);
}

function updateFamily(manifest, component, tag, digestCharacter) {
  for (const [index, image] of Object.values(
    manifest.components[component].images,
  ).entries()) {
    image.tag = tag;
    image.digest = `sha256:${digestCharacter.repeat(63)}${index + 1}`;
  }
}

test("a complete service image family update is accepted", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  updateFamily(next, "service-json-keys", "v2.6.0", "3");

  assert.doesNotThrow(() => validateImageUpdate(previous, next));
});

test("a partial service image family update is rejected", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  next.components["service-json-keys"].images.grpc.tag = "v2.6.0";
  next.components["service-json-keys"].images.grpc.digest =
    `sha256:${"3".repeat(64)}`;

  assert.throws(
    () => validateImageUpdate(previous, next),
    /must update its complete image family/,
  );
});

test("a digest mutation behind an existing SemVer tag is rejected", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  next.components["service-authentication"].images.rest.digest =
    `sha256:${"3".repeat(64)}`;

  assert.throws(
    () => validateImageUpdate(previous, next),
    /mutates an existing release tag/,
  );
});

test("complete service families may be enabled together for initial launch", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  previous.components["service-json-keys"].enabled = false;
  previous.components["service-authentication"].enabled = false;
  updateFamily(next, "service-json-keys", "v2.6.0", "3");
  updateFamily(next, "service-authentication", "v1.3.0", "4");

  assert.doesNotThrow(() => validateImageUpdate(previous, next));
});

test("a service major update remains separate from other service updates", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  updateFamily(next, "service-json-keys", "v3.0.0", "3");
  updateFamily(next, "service-authentication", "v1.3.0", "4");

  assert.throws(
    () => validateImageUpdate(previous, next),
    /service major change must be reviewed separately/,
  );
});

test("a PostgreSQL major update remains separate from service releases", () => {
  const previous = copyStableManifest();
  const next = copyStableManifest();
  next.postgresMajor = 19;
  updateFamily(next, "service-json-keys", "v2.6.0", "3");

  assert.throws(
    () => validateImageUpdate(previous, next),
    /PostgreSQL major change must be reviewed separately/,
  );
});

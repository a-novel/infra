#!/usr/bin/env node

/**
 * Validate the transition between two reviewed production image manifests.
 * Schema validation owns each manifest; this script owns invariants that only
 * exist across a pull-request diff or a receipt-owned deployment transition.
 */

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

const componentSlots = {
  "service-json-keys": [
    "database",
    "grpc",
    "jobs/migrations",
    "jobs/rotatekeys",
  ],
  "service-authentication": [
    "database",
    "jobs/init",
    "jobs/migrations",
    "rest",
  ],
};

function fail(message) {
  throw new Error(message);
}

function imageChanged(previous, next) {
  return (
    previous?.repository !== next?.repository ||
    previous?.tag !== next?.tag ||
    previous?.digest !== next?.digest
  );
}

/**
 * validateImageUpdate rejects partial service releases, mutable release tags,
 * and combined routine service releases. It returns the changed families.
 */
export function validateImageUpdate(previous, next) {
  const changedComponents = [];

  for (const [component, slots] of Object.entries(componentSlots)) {
    const previousComponent = previous.components[component];
    const nextComponent = next.components[component];
    const changedSlots = slots.filter((slot) =>
      imageChanged(previousComponent.images[slot], nextComponent.images[slot]),
    );

    if (previousComponent.enabled !== nextComponent.enabled) {
      changedSlots.push("enabled");
    }
    if (changedSlots.length === 0) continue;

    for (const slot of slots) {
      const previousImage = previousComponent.images[slot];
      const nextImage = nextComponent.images[slot];
      if (
        previousImage?.tag === nextImage?.tag &&
        previousImage?.digest !== nextImage?.digest
      ) {
        fail(`${component}/${slot} mutates an existing release tag`);
      }
    }

    const imageChangeCount = new Set(
      changedSlots.filter((slot) => slot !== "enabled"),
    ).size;
    if (imageChangeCount !== slots.length) {
      fail(`${component} must update its complete image family`);
    }

    changedComponents.push(component);
  }

  const postgresChanged = previous.postgresMajor !== next.postgresMajor;
  if (postgresChanged && changedComponents.length > 0) {
    fail("a PostgreSQL major change must be reviewed separately");
  }
  const firstLaunch = Object.values(previous.components).every(
    (component) => !component.enabled,
  );
  if (!firstLaunch && changedComponents.length > 1) {
    fail(
      "service image families must be deployed separately; deploy the preceding family before merging another",
    );
  }
  return changedComponents;
}

async function readManifest(file) {
  return parse(await readFile(file, "utf8"));
}

async function main() {
  if (process.argv.length !== 4) {
    fail(
      "usage: validate-image-update.mjs <previous-manifest> <next-manifest>",
    );
  }
  const [, , previousPath, nextPath] = process.argv;
  validateImageUpdate(
    await readManifest(previousPath),
    await readManifest(nextPath),
  );
  process.stdout.write("Production image update invariants passed.\n");
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    process.stderr.write(
      `Production image update rejected: ${error.message}\n`,
    );
    process.exitCode = 1;
  });
}

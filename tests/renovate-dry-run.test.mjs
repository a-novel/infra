import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { stringify } from "yaml";

const executeFile = promisify(execFile);
const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..");
const renovateBinary = path.join(repositoryRoot, "node_modules/.bin/renovate");

const slots = {
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

const noisyTags = [
  "latest",
  "master",
  "feat-key-rotation",
  "pr-123",
  "0123456789abcdef0123456789abcdef01234567",
  "v2",
  "v2.5",
  "v2.6.0-rc.1",
];

function digest(repository, reference) {
  return `sha256:${createHash("sha256").update(`${repository}:${reference}`).digest("hex")}`;
}

function tagsFor(repository) {
  if (repository.startsWith("a-novel/service-json-keys/")) {
    return [...noisyTags, "v2.5.0", "v2.6.0", "v3.0.0"];
  }
  return [...noisyTags, "v2.5.0"];
}

function registryResponse(request, response) {
  const url = new URL(request.url, "http://registry.invalid");
  if (url.pathname === "/v2/") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end("{}");
    return;
  }

  const tagsMatch = /^\/v2\/(.+)\/tags\/list$/.exec(url.pathname);
  if (tagsMatch) {
    const repository = decodeURIComponent(tagsMatch[1]);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({ name: repository, tags: tagsFor(repository) }),
    );
    return;
  }

  const manifestMatch = /^\/v2\/(.+)\/manifests\/(.+)$/.exec(url.pathname);
  if (manifestMatch) {
    const repository = decodeURIComponent(manifestMatch[1]);
    const reference = decodeURIComponent(manifestMatch[2]);
    const knownReference =
      reference.startsWith("sha256:") ||
      tagsFor(repository).includes(reference);
    if (!knownReference) {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ errors: [{ code: "MANIFEST_UNKNOWN" }] }));
      return;
    }

    const resolvedDigest =
      repository === "a-novel/service-authentication/rest" &&
      reference === "v2.5.0"
        ? digest(repository, "mutated-v2.5.0")
        : reference.startsWith("sha256:")
          ? reference
          : digest(repository, reference);
    const contentType = reference.startsWith("sha256:")
      ? "application/vnd.oci.image.index.v1+json"
      : "application/vnd.oci.image.manifest.v1+json";
    const headers = {
      "content-type": contentType,
      "docker-content-digest": resolvedDigest,
    };
    if (request.method === "HEAD") {
      response.writeHead(200, headers);
      response.end();
      return;
    }

    response.writeHead(200, headers);
    response.end(
      JSON.stringify({
        schemaVersion: 2,
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        config: {
          mediaType: "application/vnd.oci.image.config.v1+json",
          digest: digest(repository, "config"),
          size: 2,
        },
        layers: [],
        annotations: {
          "org.opencontainers.image.source": `https://github.com/${repository.split("/").slice(0, 2).join("/")}`,
          "org.opencontainers.image.revision": "a".repeat(40),
        },
      }),
    );
    return;
  }

  response.writeHead(404, { "content-type": "application/json" });
  response.end(JSON.stringify({ errors: [{ code: "NAME_UNKNOWN" }] }));
}

function fixtureManifest(registry) {
  const components = {};
  for (const [component, componentSlots] of Object.entries(slots)) {
    const images = {};
    for (const slot of componentSlots) {
      const repositoryPath = `a-novel/${component}/${slot}`;
      images[slot] = {
        repository: `${registry}/${repositoryPath}`,
        tag: "v2.5.0",
        digest: digest(repositoryPath, "v2.5.0"),
      };
    }
    components[component] = { enabled: true, images };
  }
  return { schemaVersion: 1, postgresMajor: 18, components };
}

function jsonRecords(output) {
  return output
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

async function runRenovateFixture() {
  const server = createServer(registryResponse);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");
  const registry = `127.0.0.1:${address.port}`;
  const scratch = await mkdtemp(path.join(tmpdir(), "infra-renovate-"));

  try {
    const config = JSON.parse(
      await readFile(path.join(repositoryRoot, "renovate.json"), "utf8"),
    );
    config.enabledManagers = ["custom.regex"];
    config.includePaths = ["deploy/production/images.yaml"];
    config.fetchChangeLogs = "off";
    config.onboarding = false;
    config.requireConfig = "required";
    config.hostRules = [
      {
        hostType: "docker",
        matchHost: registry,
        insecureRegistry: true,
      },
    ];
    for (const rule of config.packageRules) {
      if (!rule.matchPackageNames) continue;
      rule.matchPackageNames = rule.matchPackageNames.map((name) =>
        name.replace("ghcr.io/a-novel/", `${registry}/a-novel/`),
      );
    }

    await Promise.all([
      mkdir(path.join(scratch, "deploy/production"), { recursive: true }),
      mkdir(path.join(scratch, "runtime/base"), { recursive: true }),
      mkdir(path.join(scratch, "runtime/cache"), { recursive: true }),
    ]);
    await Promise.all([
      writeFile(
        path.join(scratch, "renovate.json"),
        `${JSON.stringify(config, null, 2)}\n`,
      ),
      writeFile(
        path.join(scratch, "deploy/production/images.yaml"),
        stringify(fixtureManifest(registry)),
      ),
    ]);
    await executeFile("git", ["init", "--quiet", "--initial-branch=master"], {
      cwd: scratch,
    });
    await executeFile("git", ["add", "renovate.json", "deploy"], {
      cwd: scratch,
    });
    await executeFile(
      "git",
      [
        "-c",
        "user.name=Renovate fixture",
        "-c",
        "user.email=renovate-fixture@example.invalid",
        "commit",
        "--quiet",
        "-m",
        "test: add fixture",
      ],
      { cwd: scratch },
    );

    let output;
    try {
      const result = await executeFile(
        renovateBinary,
        ["--platform=local", "--dry-run=lookup"],
        {
          cwd: scratch,
          env: {
            ...process.env,
            LOG_FORMAT: "json",
            LOG_LEVEL: "debug",
            RENOVATE_BASE_DIR: path.join(scratch, "runtime/base"),
            RENOVATE_CACHE_DIR: path.join(scratch, "runtime/cache"),
            RENOVATE_REPOSITORY_CACHE: "disabled",
          },
          maxBuffer: 4 * 1024 * 1024,
        },
      );
      output = `${result.stdout}\n${result.stderr}`;
    } catch (error) {
      output = `${error.stdout ?? ""}\n${error.stderr ?? ""}`;
      const errors = jsonRecords(output)
        .flatMap((record) => record.loggerErrors ?? [])
        .map((record) => record.msg);
      if (
        errors.length === 0 ||
        errors.some(
          (message) =>
            message !==
            "Unsupported node environment detected. Please update your node version.",
        )
      ) {
        throw error;
      }
    }
    return jsonRecords(output);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await rm(scratch, { recursive: true });
  }
}

test("Renovate dry-run groups complete stable releases and ignores noisy tags", async () => {
  const records = await runRenovateFixture();
  const packageRecord = records.find(
    (record) => record.msg === "packageFiles with updates",
  );
  assert.ok(packageRecord, "Renovate must report the fixture updates");

  const dependencies = packageRecord.config.regex.flatMap(
    (packageFile) => packageFile.deps,
  );
  const updates = dependencies.flatMap((dependency) =>
    dependency.updates.map((update) => ({
      dependency: dependency.depName,
      ...update,
    })),
  );
  assert.deepEqual(
    new Set(updates.map((update) => update.branchName)),
    new Set([
      "renovate/service-json-keys-images",
      "renovate/major-service-json-keys-images",
      "renovate/service-authentication-images",
    ]),
  );

  const jsonKeysMinor = updates.filter(
    (update) => update.branchName === "renovate/service-json-keys-images",
  );
  const jsonKeysMajor = updates.filter(
    (update) => update.branchName === "renovate/major-service-json-keys-images",
  );
  assert.equal(jsonKeysMinor.length, slots["service-json-keys"].length);
  assert.equal(jsonKeysMajor.length, slots["service-json-keys"].length);
  assert.ok(jsonKeysMinor.every((update) => update.newValue === "v2.6.0"));
  assert.ok(jsonKeysMajor.every((update) => update.newValue === "v3.0.0"));

  const authentication = updates.filter(
    (update) => update.branchName === "renovate/service-authentication-images",
  );
  assert.equal(authentication.length, 1);
  assert.equal(authentication[0].updateType, "digest");
  assert.match(authentication[0].dependency, /service-authentication\/rest$/);

  assert.ok(
    updates.every(
      (update) =>
        update.updateType === "digest" ||
        /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(
          update.newValue,
        ),
    ),
    "branch, SHA, partial, and prerelease tags must never become updates",
  );
});
